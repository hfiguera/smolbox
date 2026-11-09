defmodule SmolBox.BranchPublicAuthorityTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}
  alias SmolBox.Branches
  alias SmolBox.Embedded.Config
  alias SmolBox.Error
  alias SmolBox.ManagedMachine
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{BranchContract, Contract, Memory}

  defmodule Clock do
    def now, do: 1300
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({:native_acquire, id}, {caller, _}, state) do
      result =
        Agent.get_and_update(state.authority, fn
          nil ->
            {:ok, {id, caller}}

          holder ->
            {{:error, %Error{category: :admission_exhausted, operation: :embedded}}, holder}
        end)

      {:reply, result, state}
    end

    # This legacy coordination model has no completed native recovery scan.
    # Preserve acquisition/commit ownership without inventing readiness.
    def handle_call({:native_acquire_operation, id}, from, state) do
      case handle_call({:native_acquire, id}, from, state) do
        {:reply, :ok, next} -> {:reply, {:ok, false}, next}
        result -> result
      end
    end

    def handle_call({:native_release, id}, {caller, _}, state) do
      Agent.update(state.authority, fn {^id, ^caller} -> nil end)
      {:reply, :ok, state}
    end
  end

  defmodule Store do
    def capabilities({store, _, _}), do: Memory.capabilities(store)

    def claim_worker({store, _, _}, id, owner, now, lease),
      do: Memory.claim_worker(store, id, owner, now, lease)

    def machine({store, observer, authority}, operation, arguments) do
      if operation in [:branch_resolve, :branch_retire, :branch_release_storage] do
        caller = self()
        held = Agent.get(authority, &(&1 == {"worker", caller}))
        send(observer, {:store_transition, operation, held})

        if held,
          do: Memory.machine(store, operation, arguments),
          else: {:error, %Error{category: :store, operation: :branch}}
      else
        Memory.machine(store, operation, arguments)
      end
    end
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:quiesce, epoch}, _, state) do
      send(state.observer, {:quiesce, epoch})

      result =
        cond do
          epoch != state.epoch ->
            {:error, %Error{category: :identity_conflict, operation: :embedded}}

          state.busy ->
            {:error, %Error{category: :admission_exhausted, operation: :embedded}}

          true ->
            :ok
        end

      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:observe, record, operation}, _, state) do
      send(state.observer, {:observe, ManagedMachine.key(record), operation, state.frozen})
      result = if operation == :inspect_machine, do: {:ok, state.source}, else: {:ok, :absent}
      {:reply, result, state}
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, op), do: op in [:inspect_machine, :branch_absent]
    def pin(context, _), do: {:ok, context}
    def assign(context, record), do: {:ok, %{context | managed_machine: record}}

    def invoke(context, operation, _, _),
      do: GenServer.call(context.server, {:observe, context.managed_machine, operation})
  end

  # Valid public branch/store records plus semantic native channel/owner peers.
  # This models coordination, not native assignment enrollment or SDK behavior.
  defp fixture(options \\ []) do
    store = start_supervised!(Memory)
    authority = start_supervised!({Agent, fn -> nil end})
    source = BranchContract.running(Memory, store)
    {:ok, _} = BranchContract.accept(Memory, store, source)
    {:ok, _} = BranchContract.advance(Memory, store, source, :accepted, :dispatching)
    {:ok, child} = BranchContract.advance(Memory, store, source, :dispatching, :unknown)
    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           epoch: epoch,
           source: source.created_machine,
           frozen: false,
           busy: options[:busy] || false
         }}
      )

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: "worker",
      context: %EmbeddedContext{
        config: struct(Config),
        server: peer,
        pinned: true,
        epoch: if(options[:stale], do: String.duplicate("b", 32), else: epoch)
      },
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 4096, max_response_bytes: 8192}
    }

    target = %Target{kind: :embedded, id: "worker", connection: reference}

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority}},
      workers: [target],
      owner: "owner",
      clock: Clock,
      lease_ms: 10_000,
      poll_ms: 20
    }

    host = %{
      id: Coordinator,
      start: {Host, :start_link, [%{config: config, authority: authority}]}
    }

    work = %{
      id: WorkSupervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [[host], [strategy: :one_for_one]]}
    }

    runtime =
      start_supervised!(%{
        id: :model_runtime,
        type: :supervisor,
        start: {Supervisor, :start_link, [[work], [strategy: :one_for_one]]}
      })

    %{runtime: runtime, store: store, child: child, source: source, authority: authority}
  end

  test "explicit resolution, retirement and storage release retain authority through store commits" do
    f = fixture()
    key = ManagedMachine.key(f.child)
    source_key = ManagedMachine.key(f.source)

    assert {:ok, %{branch: %{state: :resolved}}} =
             Branches.resolve(f.runtime, key, quiesced: true, disposition: :deleted)

    assert_received {:observe, ^source_key, :inspect_machine, true}
    assert_received {:observe, ^key, :branch_absent, true}
    assert_received {:store_transition, :branch_resolve, true}
    assert Agent.get(f.authority, & &1) == nil
    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "worker")
    assert {:ok, %{branch: %{state: :retired}}} = Branches.retire(f.runtime, key, quiesced: true)
    assert_received {:observe, ^key, :branch_absent, true}
    assert_received {:store_transition, :branch_retire, true}
    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "worker")
    {:ok, source} = Memory.machine(f.store, :fetch, [source_key])

    {:ok, missing} =
      Memory.machine(f.store, :write, [
        source_key,
        Contract.guard(source),
        [state: :missing],
        1300
      ])

    {:ok, _} =
      Memory.machine(f.store, :resolve, [source_key, Contract.guard(missing), :absent, 1300])

    assert {:ok, %{branch: %{state: :closed}}} =
             Branches.release_storage(f.runtime, key, backing_removed: true)

    assert_received {:observe, ^source_key, :branch_absent, true}
    assert_received {:observe, ^key, :branch_absent, true}
    assert_received {:store_transition, :branch_release_storage, true}
    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(f.store, "worker")
    assert Agent.get(f.authority, & &1) == nil
  end

  for option <- [:busy, :stale] do
    test "#{option} helper cannot produce retirement evidence or release accounting" do
      f = fixture([{unquote(option), true}])
      key = ManagedMachine.key(f.child)
      assert {:ok, before} = Memory.usage(f.store, "worker")
      assert {:error, _} = Branches.resolve(f.runtime, key, quiesced: true, disposition: :deleted)
      refute_received {:observe, _, _, _}
      refute_received {:store_transition, _, _}
      assert {:ok, ^before} = Memory.usage(f.store, "worker")
      assert Agent.get(f.authority, & &1) == nil
    end
  end

  test "concurrent native authority blocks observations before any store transition" do
    f = fixture()
    Agent.update(f.authority, fn _ -> {"worker", :other_holder} end)

    assert {:error, %{category: :admission_exhausted}} =
             Branches.resolve(f.runtime, ManagedMachine.key(f.child),
               quiesced: true,
               disposition: :deleted
             )

    refute_received {:quiesce, _}
    refute_received {:observe, _, _, _}
    refute_received {:store_transition, _, _}
    assert {:ok, %{slots: 3}} = Memory.usage(f.store, "worker")
  end
end
