defmodule SmolBox.NativeReleasedBranchPublicContinuationTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, Machines, ManagedMachine, Profile}

  alias SmolBox.Backend.{Budget, EmbeddedBranchDeletionAction, EmbeddedContext, Reference}
  alias SmolBox.Embedded.{Config, NativeGrowth}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Memory, NativeBranchDeletionContract}
  alias SmolBox.Store.NativeBranchDeletionActionContract, as: ActionContract
  alias SmolBox.Store.NativeReleasedBranchCleanupContract, as: CleanupContract
  alias SmolBox.Store.NativeReleasedBranchContinuationContract, as: ContinuationContract

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

    def machine({_, _, _, _, flags} = context, operation, arguments) do
      if operation == :claim and Agent.get(flags, & &1[:renew_armed]),
        do: {:error, %Error{category: :store, operation: :store}},
        else: guarded_machine(context, operation, arguments)
    end

    defp guarded_machine({store, observer, authority, worker, flags}, operation, arguments) do
      if operation in [:branch_delete_action_accept, :branch_delete_action_complete] do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_operation, operation, held})
        options = Agent.get(flags, & &1)

        if operation == :branch_delete_action_complete and options[:stale_commit] do
          [key | _] = arguments
          {:ok, _} = Memory.machine(store, :claim, [key, "owner", 1400, 10_000])
        end

        if operation == :branch_delete_action_accept,
          do: Process.sleep(options[:accept_delay] || 0)

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
      ExUnit.Assertions.assert(
        operation["operation"] == "#{state.action}_released_branch_deletion"
      )

      arm_renewal_failure(state)
      request = operation["request"]
      {:ok, child} = Memory.machine(state.store, :fetch, [ManagedMachine.key(state.child)])
      persisted = ActionContract.saved(child, state.action).request == request

      send(
        state.observer,
        {:proof, state.frozen, context.quiesced, context.epoch, persisted,
         context.server == self()}
      )

      if state.request != nil, do: ExUnit.Assertions.assert(state.request == request)

      proof = proof(state.action, request)

      response =
        {:ok,
         %{
           "result" => result(state.action),
           "proof" =>
             Map.new(Map.from_struct(proof), fn {key, value} -> {Atom.to_string(key), value} end)
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

          :before_entry ->
            {:error,
             %Error{category: :validation, operation: :reconcile, evidence: :not_dispatched}}

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

    defp arm_renewal_failure(%{renew_failure: true, flags: flags}),
      do: Agent.update(flags, &Keyword.put(&1, :renew_armed, true))

    defp arm_renewal_failure(_), do: :ok

    defp proof(:cleanup, request), do: CleanupContract.proof(request)
    defp proof(:continue, request), do: ContinuationContract.proof(request)

    defp result(:continue), do: "released_branch_deletion_continued"
    defp result(:cleanup), do: "released_branch_deletion_cleaned"
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, op),
      do: op in [:continue_branch_deletion, :cleanup_branch_deletion]

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

    def invoke(context, operation, [child], budget) do
      action = if operation == :continue_branch_deletion, do: :continue, else: :cleanup

      EmbeddedBranchDeletionAction.coordinate(context, child, action, budget, fn scoped,
                                                                                 request,
                                                                                 _ ->
        GenServer.call(scoped.server, {:proof, request, scoped})
      end)
    end
  end

  defp fixture(origin, action, options) do
    store = start_supervised!(Memory)

    {parent, child, usage} = NativeBranchDeletionContract.prepare(Memory, store, origin)

    authority = start_supervised!({Agent, fn -> nil end})
    flags = start_supervised!(%{id: :flags, start: {Agent, :start_link, [fn -> options end]}})
    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           flags: flags,
           renew_failure: options[:renew_failure],
           action: action,
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

  defp api(:continue), do: :continue_deletion
  defp api(:cleanup), do: :cleanup_deletion

  defp execute(runtime, child, action, options \\ [quiesced: true]),
    do: apply(Machines, api(action), [runtime, ManagedMachine.key(child), child.version, options])

  for origin <- [:ready, :released] do
    for action <- [:continue, :cleanup] do
      test "#{origin} #{action} keeps acceptance dispatch and final proof under one captured native fence" do
        action = unquote(action)

        {runtime, store, parent, child, usage, authority, peer} =
          fixture(unquote(origin), action, delay: 45)

        assert {:ok, gone} = execute(runtime, child, action)
        assert gone.state == :deleted and gone.branch.state == child.branch.state
        assert_receive {:quiesce, :ok}
        assert_receive {:store_operation, :branch_delete_action_accept, true}
        assert_receive {:proof, true, true, _, true, true}
        assert_receive {:store_operation, :branch_delete_action_complete, true}

        expected =
          Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

        assert {:ok, ^expected} = Memory.usage(store, parent.worker_id)
        assert NativeBranchDeletionContract.fetch(Memory, store, parent) == parent
        assert parent.branch_children[child.id] == false
        assert Agent.get(authority, & &1) == nil
        assert GenServer.call(peer, :calls) == 1
        assert ActionContract.saved(gone, action).proof != nil
        assert {:ok, ^gone} = execute(runtime, gone, action)
        assert GenServer.call(peer, :calls) == 1
        refute_receive {:quiesce, _}
        refute_receive {:store_operation, _, _}
      end

      for option <- [:busy, :stale_epoch] do
        test "#{origin} #{action} #{option} rejects before durable acceptance and native IO" do
          action = unquote(action)

          {runtime, store, parent, child, usage, authority, peer} =
            fixture(unquote(origin), action, [{unquote(option), true}])

          assert {:error, _} = execute(runtime, child, action)
          saved = NativeBranchDeletionContract.fetch(Memory, store, child)
          assert ActionContract.saved(saved, action) == nil
          assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
          assert GenServer.call(peer, :calls) == 0
          assert Agent.get(authority, & &1) == nil
        end
      end

      test "#{origin} #{action} wrong expected version and missing quiescence cannot accept a request" do
        action = unquote(action)
        {runtime, store, parent, child, usage, _, peer} = fixture(unquote(origin), action, [])

        assert {:error, _} =
                 apply(Machines, api(action), [
                   runtime,
                   ManagedMachine.key(child),
                   child.version + 1,
                   [quiesced: true]
                 ])

        for options <- [[], [quiesced: false], [quiesced: true, disposition: :deleted]] do
          assert {:error, _} = execute(runtime, child, action, options)
        end

        assert ActionContract.saved(
                 NativeBranchDeletionContract.fetch(Memory, store, child),
                 action
               ) == nil

        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert GenServer.call(peer, :calls) == 0
      end

      for mode <- [:bare, :wrong_proof, :output, :overlay] do
        test "#{origin} #{action} #{mode} retains accepted intent and all charges without final commit" do
          action = unquote(action)

          {runtime, store, parent, child, usage, authority, _} =
            fixture(unquote(origin), action, mode: unquote(mode))

          assert {:error, %Error{evidence: :dispatch_uncertain}} = execute(runtime, child, action)
          saved = NativeBranchDeletionContract.fetch(Memory, store, child)
          assert saved.state == :unknown and ActionContract.saved(saved, action).proof == nil
          assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
          assert Agent.get(authority, & &1) == nil
          refute_receive {:store_operation, :branch_delete_action_complete, _}
        end
      end

      test "#{origin} #{action} retry retains the same request after a lost acknowledgement and later claims" do
        action = unquote(action)

        {runtime, store, parent, child, usage, _, peer} =
          fixture(unquote(origin), action, mode: :missing_once)

        assert {:error, _} = execute(runtime, child, action)
        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        request = ActionContract.saved(saved, action).request
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert {:ok, gone} = execute(runtime, saved, action)
        assert ActionContract.saved(gone, action).request == request
        assert GenServer.call(peer, :calls) == 2
      end

      test "#{origin} #{action} final guard conflict remains uncertain and retains the child slot" do
        action = unquote(action)

        {runtime, store, parent, child, usage, authority, _} =
          fixture(unquote(origin), action, stale_commit: true)

        assert {:error, %Error{evidence: :dispatch_uncertain}} = execute(runtime, child, action)
        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        assert saved.state == :unknown and ActionContract.saved(saved, action).proof == nil
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert_receive {:store_operation, :branch_delete_action_complete, true}
        assert Agent.get(authority, & &1) == nil
      end

      test "#{origin} #{action} acceptance consuming its deadline never dispatches" do
        action = unquote(action)

        {runtime, store, parent, child, usage, authority, peer} =
          fixture(unquote(origin), action, budget: 1500, accept_delay: 2000)

        assert {:error, %Error{evidence: :not_dispatched}} = execute(runtime, child, action)
        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        assert ActionContract.saved(saved, action).proof == nil
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert GenServer.call(peer, :calls) == 0
        assert Agent.get(authority, & &1) == nil
      end

      test "#{origin} #{action} an observation timeout remains uncertain without committing a late response" do
        action = unquote(action)

        {runtime, store, parent, child, usage, authority, peer} =
          fixture(unquote(origin), action, budget: 1500, delay: 2000)

        assert {:error, %Error{evidence: :dispatch_uncertain}} = execute(runtime, child, action)
        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        assert ActionContract.saved(saved, action).proof == nil
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert GenServer.call(peer, :calls) == 1
        assert Agent.get(authority, & &1) == nil
        refute_receive {:store_operation, :branch_delete_action_complete, _}
      end

      test "#{origin} #{action} renewal failure during IO keeps uncertainty and accepted authority" do
        action = unquote(action)

        {runtime, store, parent, child, usage, authority, peer} =
          fixture(unquote(origin), action, delay: 500, renew_failure: true)

        assert {:error, %Error{category: :store, evidence: :dispatch_uncertain}} =
                 execute(runtime, child, action)

        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        assert saved.state == :unknown and ActionContract.saved(saved, action).proof == nil
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
        assert GenServer.call(peer, :calls) == 1
        assert Agent.get(authority, & &1) == nil
        refute_receive {:store_operation, :branch_delete_action_complete, _}
      end

      test "#{origin} #{action} a definitive pre-entry rejection preserves not-dispatched evidence" do
        action = unquote(action)

        {runtime, store, parent, child, usage, _, _} =
          fixture(unquote(origin), action, mode: :before_entry)

        assert {:error, %Error{evidence: :not_dispatched}} = execute(runtime, child, action)
        saved = NativeBranchDeletionContract.fetch(Memory, store, child)
        assert ActionContract.saved(saved, action).proof == nil
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      end
    end
  end
end
