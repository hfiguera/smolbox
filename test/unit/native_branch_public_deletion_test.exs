defmodule SmolBox.NativeBranchPublicDeletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, Machines, ManagedMachine, Profile}

  alias SmolBox.Backend.{Budget, EmbeddedBranchDeletion, EmbeddedContext, Reference}
  alias SmolBox.Embedded.{BranchDeletionResolution, Config, NativeGrowth}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Memory, NativeBranchDeletionContract}

  defmodule Clock do
    def now, do: 1400
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({:native_acquire_operation, id}, {caller, _}, state) do
      result =
        Agent.get_and_update(state.authority, fn
          nil -> {{:ok, false}, {id, caller}}
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
      if operation in [:branch_delete_accept, :resolve] do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_operation, operation, held})
        options = Agent.get(flags, & &1)

        if operation == :resolve and options[:stale_commit] do
          [key | _] = arguments
          {:ok, _} = Memory.machine(store, :claim, [key, "owner", 1400, 10_000])
        end

        if operation == :branch_delete_accept, do: Process.sleep(options[:accept_delay] || 0)

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
      persisted = child.branch.native_authority.deletion.request == request

      send(
        state.observer,
        {:proof, state.frozen, context.quiesced, context.epoch, persisted,
         context.server == self()}
      )

      if state.request != nil, do: ExUnit.Assertions.assert(state.request == request)
      proof = NativeBranchDeletionContract.proof(request)

      response =
        {:ok,
         %{
           "result" => "held_branch_deletion_resolved",
           "proof" => BranchDeletionResolution.to_wire(proof)
         }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

      response =
        case state.mode do
          :bare ->
            {:ok, :absent}

          :wrong_proof ->
            put_elem(
              response,
              1,
              put_in(elem(response, 1), ~w(proof deletion_sha256), String.duplicate("b", 64))
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
    def supports_operation?(_, op), do: op == :resolve_branch_deletion
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
           branch_deletion: record
       }}
    end

    def invoke(context, :resolve_branch_deletion, [child], budget),
      do:
        EmbeddedBranchDeletion.coordinate(context, child, budget, fn scoped, request, _ ->
          GenServer.call(scoped.server, {:proof, request, scoped})
        end)
  end

  defp fixture(options) do
    store = start_supervised!(Memory)

    {parent, child, usage} = NativeBranchDeletionContract.prepare(Memory, store)

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
        timeout_ms: options[:budget] || 5000,
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

  defp resolve(runtime, child),
    do:
      Machines.resolve(runtime, ManagedMachine.key(child), child.version,
        quiesced: true,
        disposition: :deleted
      )

  test "public held-delete resolution keeps both store writes under the native fence and preserves backing" do
    {runtime, store, parent, child, usage, authority, peer} = fixture(delay: 45)
    assert {:ok, gone} = resolve(runtime, child)
    assert gone.state == :deleted and gone.branch.state == :held
    assert_receive {:quiesce, :ok}
    assert_receive {:store_operation, :branch_delete_accept, true}
    assert_receive {:proof, true, true, _, true, true}
    assert_receive {:store_operation, :resolve, true}
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = Memory.usage(store, parent.worker_id)
    assert NativeBranchDeletionContract.fetch(Memory, store, parent) == parent
    assert parent.branch_children[child.id] == false
    assert Agent.get(authority, & &1) == nil
    assert GenServer.call(peer, :calls) == 1
  end

  for option <- [:busy, :stale_epoch] do
    test "#{option} rejects before request acceptance and native proof IO" do
      {runtime, store, parent, child, usage, authority, peer} = fixture([{unquote(option), true}])
      assert {:error, _} = resolve(runtime, child)
      saved = NativeBranchDeletionContract.fetch(Memory, store, child)
      assert saved.branch.native_authority.deletion == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert GenServer.call(peer, :calls) == 0
      assert Agent.get(authority, & &1) == nil
    end
  end

  test "wrong public expected version cannot accept a resolution request" do
    {runtime, store, parent, child, usage, _, peer} = fixture([])

    assert {:error, _} =
             Machines.resolve(runtime, ManagedMachine.key(child), child.version + 1,
               quiesced: true,
               disposition: :deleted
             )

    assert NativeBranchDeletionContract.fetch(Memory, store, child).branch.native_authority.deletion ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert GenServer.call(peer, :calls) == 0
  end

  for mode <- [:bare, :wrong_proof, :output, :overlay] do
    test "#{mode} leaves resolution pending with ordinary and backing charges retained" do
      {runtime, store, parent, child, usage, authority, _} = fixture(mode: unquote(mode))
      assert {:error, _} = resolve(runtime, child)
      saved = NativeBranchDeletionContract.fetch(Memory, store, child)
      assert saved.state == :unknown and saved.branch.native_authority.deletion.proof == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      refute_receive {:store_operation, :resolve, _}
    end
  end

  test "explicit retry uses the same accepted request after a missing acknowledgement and later claims" do
    {runtime, store, parent, child, usage, _, peer} = fixture(mode: :missing_once)
    assert {:error, _} = resolve(runtime, child)
    saved = NativeBranchDeletionContract.fetch(Memory, store, child)
    request = saved.branch.native_authority.deletion.request
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert {:ok, gone} = resolve(runtime, saved)
    assert gone.branch.native_authority.deletion.request == request
    assert GenServer.call(peer, :calls) == 2
  end

  test "final source-of-truth guard conflict retains the accepted request and child slot" do
    {runtime, store, parent, child, usage, authority, _} = fixture(stale_commit: true)
    assert {:error, _} = resolve(runtime, child)
    saved = NativeBranchDeletionContract.fetch(Memory, store, child)
    assert saved.state == :unknown and saved.branch.native_authority.deletion.proof == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert_receive {:store_operation, :resolve, true}
    assert Agent.get(authority, & &1) == nil
  end

  test "acceptance consuming the deadline cannot dispatch native resolution" do
    {runtime, store, parent, child, usage, authority, peer} =
      fixture(budget: 1500, accept_delay: 2000)

    assert {:error, _} = resolve(runtime, child)
    assert_received {:store_operation, :branch_delete_accept, true}
    saved = NativeBranchDeletionContract.fetch(Memory, store, child)
    assert saved.branch.native_authority.deletion.proof == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert GenServer.call(peer, :calls) == 0
    assert Agent.get(authority, & &1) == nil
  end
end
