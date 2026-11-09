defmodule SmolBox.NativeBranchPublicRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{Budget, EmbeddedBranchRetirement, EmbeddedContext, Reference}
  alias SmolBox.Embedded.{BranchChildAbsence, Config, NativeGrowth}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Memory, NativeBranchRetirementContract}

  defmodule Clock do
    def now, do: 1400
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    # This semantic host has never completed a startup scan. Ordinary proof
    # routing must not manufacture readiness or activate a bridge for it.
    def handle_call({:native_acquire_operation, id}, from, state) do
      case handle_call({:native_acquire, id}, from, state) do
        {:reply, :ok, next} -> {:reply, {:ok, false}, next}
        result -> result
      end
    end

    def handle_call({:native_acquire, id}, {caller, _}, state) do
      result =
        Agent.get_and_update(state.authority, fn
          nil -> {:ok, {id, caller}}
          held -> {{:error, %Error{category: :admission_exhausted, operation: :embedded}}, held}
        end)

      {:reply, result, state}
    end

    def handle_call({:native_release, id}, {caller, _}, state) do
      Agent.update(state.authority, fn {^id, ^caller} -> nil end)
      {:reply, :ok, state}
    end
  end

  defmodule Store do
    def capabilities({store, _, _, _}), do: Memory.capabilities(store)

    def claim_worker({store, _, _, _}, id, owner, now, lease),
      do: Memory.claim_worker(store, id, owner, now, lease)

    def machine({store, observer, authority, worker}, operation, arguments) do
      if operation == :branch_retire do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_retirement, held})

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
      result =
        if state.busy or epoch != state.epoch,
          do: {:error, %Error{category: :identity_conflict, operation: :embedded}},
          else: :ok

      send(state.observer, {:quiesce, result})
      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:proof, request, context}, _, state) do
      send(state.observer, {:proof, state.frozen, context.quiesced, context.epoch})

      if state.stale do
        {:ok, _} =
          Memory.machine(state.store, :claim, [
            ManagedMachine.key(state.child),
            "owner",
            1400,
            10_000
          ])
      end

      result =
        if state.bare,
          do: {:ok, :absent},
          else:
            {:ok,
             %{
               "result" => "branch_child_absent",
               "proof" =>
                 BranchChildAbsence.to_wire(
                   NativeBranchRetirementContract.proof_from_request(request["request"])
                 )
             }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

      {:reply, result, state}
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, op), do: op == :branch_absent
    def pin(context, _), do: {:ok, context}

    def assign(context, record) do
      {:ok, identity} = NativeGrowth.current_identity(record)

      {:ok,
       %{
         context
         | assignment: record.backend_assignment,
           spec: record.spec,
           profile: record.spec.profile,
           name: record.machine_name,
           identity: identity,
           branch_retirement: record
       }}
    end

    def invoke(context, :branch_absent, [name], budget),
      do:
        EmbeddedBranchRetirement.coordinate(context, name, budget, fn scoped, request, _budget ->
          GenServer.call(scoped.server, {:proof, request, scoped})
        end)
  end

  defp fixture(options \\ []) do
    store = start_supervised!(Memory)
    {parent, child, _, usage} = NativeBranchRetirementContract.prepare(Memory, store, :released)
    authority = start_supervised!({Agent, fn -> nil end})
    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           epoch: epoch,
           frozen: false,
           child: child,
           store: store,
           busy: options[:busy] || false,
           bare: options[:bare] || false,
           stale: options[:stale_child] || false
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: peer,
      pinned: true,
      epoch: if(options[:stale_epoch], do: String.duplicate("b", 32), else: epoch)
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: parent.worker_id,
      context: context,
      budget: %Budget{timeout_ms: 5000, max_request_bytes: 131_072, max_response_bytes: 131_072}
    }

    target = %Target{kind: :embedded, id: parent.worker_id, connection: reference}

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority, parent.worker_id}},
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

    {runtime, store, parent, child, usage, authority}
  end

  test "public native retirement carries successful helper fence through proof and paired guarded store commit" do
    {runtime, store, parent, child, usage, authority} = fixture()
    assert {:ok, retired} = Branches.retire(runtime, ManagedMachine.key(child), quiesced: true)
    assert retired.branch.state == :retired
    assert_receive {:quiesce, :ok}
    assert_receive {:proof, true, true, _epoch}
    assert_receive {:store_retirement, true}
    assert Agent.get(authority, & &1) == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert {:ok, source} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert source.branch_children[child.id]
  end

  for option <- [:busy, :stale_epoch, :bare, :stale_child] do
    test "#{option} cannot retire the source dependency or release backing" do
      {runtime, store, parent, child, usage, authority} = fixture([{unquote(option), true}])
      assert {:error, _} = Branches.retire(runtime, ManagedMachine.key(child), quiesced: true)
      assert {:ok, source} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert source.branch_children[child.id] == false
      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
      assert saved.branch.native_authority.retirement == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
    end
  end
end
