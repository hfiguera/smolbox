defmodule SmolBox.NativeBranchPublicBackingTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{Budget, EmbeddedBranchBacking, EmbeddedContext, Reference}
  alias SmolBox.Embedded.{BranchBackingRelease, Config, NativeGrowth}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Memory, NativeBranchBackingContract, NativeBranchRetirementContract}

  defmodule Clock do
    def now, do: 1400
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

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
    def capabilities({store, _, _, _, _}), do: Memory.capabilities(store)

    def claim_worker({store, _, _, _, _}, id, owner, now, lease),
      do: Memory.claim_worker(store, id, owner, now, lease)

    def machine({store, observer, authority, worker, flags}, operation, arguments) do
      if operation in [:branch_backing_accept, :branch_release_storage] do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_operation, operation, held})
        options = Agent.get(flags, & &1)

        if operation == :branch_release_storage and options[:stale_commit] do
          [key | _] = arguments
          {:ok, _} = Memory.machine(store, :claim, [key, "owner", 1400, 10_000])
        end

        if operation == :branch_backing_accept, do: Process.sleep(options[:accept_delay] || 0)

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

    def handle_call({:proof, operation, context}, _, state) do
      request = operation["request"]
      {:ok, child} = Memory.machine(state.store, :fetch, [ManagedMachine.key(state.child)])
      persisted = child.branch.native_authority.backing.request == request

      send(
        state.observer,
        {:proof, state.frozen, context.quiesced, context.epoch, persisted,
         context.server == self()}
      )

      if state.request != nil, do: ExUnit.Assertions.assert(state.request == request)
      proof = NativeBranchBackingContract.proof(request)

      response =
        {:ok,
         %{"result" => "branch_backing_released", "proof" => BranchBackingRelease.to_wire(proof)},
         %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

      response =
        case state.mode do
          :bare ->
            {:ok, :absent}

          :wrong_charge ->
            put_elem(
              response,
              1,
              put_in(elem(response, 1), ~w(proof native_bytes), proof.native_bytes + 1)
            )

          :output ->
            put_elem(response, 2, %{stdout: <<>>, stderr: <<>>, file: "extra"})

          :overlay ->
            put_elem(response, 3, %Error{category: :unknown, operation: :branch})

          :missing_once when state.request == nil ->
            {:error,
             %Error{category: :unknown, operation: :branch, evidence: :dispatch_uncertain}}

          _ ->
            response
        end

      Process.sleep(state.delay)
      {:reply, response, %{state | request: request, calls: state.calls + 1}}
    end

    def handle_call(:calls, _, state), do: {:reply, state.calls, state}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, op), do: op == :release_branch_backing
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

    def invoke(context, :release_branch_backing, [parent, child, removed], budget),
      do:
        EmbeddedBranchBacking.coordinate(context, parent, child, removed, budget, fn scoped,
                                                                                     request,
                                                                                     _ ->
          GenServer.call(scoped.server, {:proof, request, scoped})
        end)
  end

  defp fixture(options) do
    store = start_supervised!(Memory)

    {parent, child, usage} =
      if options[:source_running] do
        {parent, child, _, usage} =
          NativeBranchRetirementContract.complete(Memory, store, :released)

        {parent, child, usage}
      else
        NativeBranchBackingContract.prepare(Memory, store, :released)
      end

    authority = start_supervised!({Agent, fn -> nil end})
    flags = start_supervised!(%{id: :flags, start: {Agent, :start_link, [fn -> options end]}})
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
           mode: options[:mode],
           delay: options[:delay] || 0,
           request: nil,
           calls: 0
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
      budget: %Budget{
        timeout_ms: options[:budget] || 1000,
        max_request_bytes: 131_072,
        max_response_bytes: 131_072
      }
    }

    target = %Target{kind: :embedded, id: parent.worker_id, connection: reference, draining: true}

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority, parent.worker_id, flags}},
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

    {runtime, store, parent, child, usage, authority, peer}
  end

  test "public release saves intent under the fence before IO and holds it through exact closure on a draining worker" do
    {runtime, store, parent, child, usage, authority, peer} = fixture(delay: 45)

    assert {:ok, closed} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    assert closed.branch.state == :closed
    assert_receive {:quiesce, :ok}
    assert_receive {:store_operation, :branch_backing_accept, true}
    assert_receive {:proof, true, true, _, true, true}
    assert_receive {:store_operation, :branch_release_storage, true}
    expected = Map.merge(usage, child.branch.spec.policy.resources, fn _, a, b -> a - b end)
    assert {:ok, ^expected} = Memory.usage(store, parent.worker_id)
    assert Agent.get(authority, & &1) == nil

    assert {:ok, ^closed} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    assert GenServer.call(peer, :calls) == 1
    refute_receive {:quiesce, _}
  end

  for option <- [:busy, :stale_epoch, :source_running] do
    test "#{option} rejects before accepted backing or native accounting work" do
      {runtime, store, parent, child, usage, authority, peer} = fixture([{unquote(option), true}])

      assert {:error, _} =
               Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

      saved = NativeBranchBackingContract.fetch(Memory, store, child)
      assert saved.branch.native_authority.backing == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert GenServer.call(peer, :calls) == 0
      assert Agent.get(authority, & &1) == nil
    end
  end

  for mode <- [:bare, :wrong_charge, :output, :overlay] do
    test "#{mode} leaves exact durable intent pending with all backing charged" do
      {runtime, store, parent, child, usage, authority, _} = fixture(mode: unquote(mode))

      assert {:error, _} =
               Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

      saved = NativeBranchBackingContract.fetch(Memory, store, child)
      assert saved.branch.state == :retired and saved.branch.native_authority.backing.proof == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      refute_receive {:store_operation, :branch_release_storage, _}
    end
  end

  test "explicit retry after a missing acknowledgement preserves original request across later claims" do
    {runtime, store, parent, child, usage, _, peer} = fixture(mode: :missing_once)

    assert {:error, _} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    saved = NativeBranchBackingContract.fetch(Memory, store, child)
    request = saved.branch.native_authority.backing.request
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, closed} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    assert closed.branch.native_authority.backing.request == request
    assert GenServer.call(peer, :calls) == 2
  end

  test "source guard conflict at final commit retains accepted intent and public backing" do
    {runtime, store, parent, child, usage, authority, _} = fixture(stale_commit: true)

    assert {:error, _} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    saved = NativeBranchBackingContract.fetch(Memory, store, child)
    assert saved.branch.state == :retired and saved.branch.native_authority.backing.proof == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert_receive {:store_operation, :branch_release_storage, true}
    assert Agent.get(authority, & &1) == nil
  end

  test "deadline after intent acceptance retains backing without entering the peer" do
    {runtime, store, parent, child, usage, authority, peer} =
      fixture(budget: 50, accept_delay: 100)

    assert {:error, _} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

    saved = NativeBranchBackingContract.fetch(Memory, store, child)
    assert saved.branch.native_authority.backing.proof == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert GenServer.call(peer, :calls) == 0
    assert Agent.get(authority, & &1) == nil
  end
end
