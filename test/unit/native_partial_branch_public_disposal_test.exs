defmodule SmolBox.NativePartialBranchPublicDisposalTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine, Profile}

  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedPartialBranchDisposal, Reference}

  alias SmolBox.Embedded.{
    Config,
    NativeGrowth,
    PartialBranchDisposal
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativePartialBranchCollectionContract,
    NativePartialBranchDisposalContract,
    NativeUnbootedBranchDisposalContract
  }

  alias NativePartialBranchDisposalContract, as: Contract

  defmodule Clock do
    def now, do: 1400
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({:native_acquire, id}, {caller, _}, state) do
      reply =
        Agent.get_and_update(state.authority, fn
          nil -> {:ok, {id, caller}}
          held -> {{:error, %Error{category: :admission_exhausted, operation: :embedded}}, held}
        end)

      {:reply, reply, state}
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

    def machine({store, observer, authority, worker, mode}, operation, args) do
      if operation in [:branch_advance, :branch_resolve] do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_write, operation, held})

        if held and not (operation == :branch_advance and mode == :accept_failure) and
             not (operation == :branch_resolve and mode == :store_failure),
           do: Memory.machine(store, operation, args),
           else: {:error, %Error{category: :store, operation: :branch}}
      else
        Memory.machine(store, operation, args)
      end
    end
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, Map.merge(state, %{disposed: nil, observations: 0})}

    def handle_call({:quiesce, epoch}, _, state) do
      result =
        if epoch == state.epoch,
          do: :ok,
          else: {:error, %Error{category: :identity_conflict, operation: :embedded}}

      if state.mode == :stale_before_accept,
        do:
          Memory.machine(state.store, :claim, [
            ManagedMachine.key(state.child),
            "owner",
            1400,
            10_000
          ])

      send(state.observer, {:quiesce, result})
      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:call, context, request, budget, child}, _, state) do
      send(
        state.observer,
        {:native_call, request["operation"], state.frozen, context.quiesced, context.epoch,
         request, budget}
      )

      {response, state} = respond(context, request, child, state)
      {:reply, response, state}
    end

    defp respond(
           _,
           %{"operation" => "resolve_partial_branch_disposal"},
           child,
           %{disposed: nil} = state
         ) do
      case state.mode do
        :unknown_observation ->
          {uncertain(), state}

        :resolved_absent ->
          result = Contract.result(child, state.metadata, "resolved_absent")
          {proof(result), %{state | disposed: result}}

        _ ->
          {failure(), state}
      end
    end

    defp respond(_, %{"operation" => "resolve_partial_branch_disposal"}, _, state),
      do: {proof(state.disposed), state}

    defp respond(
           _,
           %{"operation" => "dispose_partial_branch"},
           _,
           %{mode: :not_dispatched} = state
         ),
         do: {failure(), state}

    defp respond(
           _,
           %{"operation" => "dispose_partial_branch", "request" => request},
           child,
           state
         ) do
      if state.disposed != nil, do: true = state.disposed.proof.request == request
      result = state.disposed || Contract.result(child, state.metadata)
      send(state.observer, :modeled_delete_entry)

      if state.mode == :stale_child,
        do:
          Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])

      response =
        case state.mode do
          :lost_disposal when state.disposed == nil ->
            uncertain()

          :output ->
            {:ok, outcome, empty, nil} = proof(result)
            {:ok, outcome, %{empty | stdout: "unexpected"}, nil}

          :cursor ->
            {:ok, outcome, empty, nil} = proof(result)
            {:ok, outcome, empty, "unexpected"}

          _ ->
            proof(result)
        end

      {response, %{state | disposed: result}}
    end

    defp respond(context, %{"operation" => "inspect"}, _, state) do
      pid = state.metadata.source.backend_identity.pid_identity
      pid = if state.mode == :wrong_source, do: [999, 999], else: pid

      response =
        if state.mode == :lost_source and state.observations == 0,
          do: uncertain(),
          else:
            {:ok,
             %{
               "result" => "observed",
               "observation" => %{
                 "resources" => EmbeddedContext.resources(context),
                 "state" => "running",
                 "pid_identity" => pid
               }
             }, empty(), nil}

      {response, %{state | observations: state.observations + 1}}
    end

    defp proof(result),
      do:
        {:ok,
         %{
           "result" => "partial_branch_disposed",
           "proof" => PartialBranchDisposal.to_wire(result.proof)
         }, empty(), nil}

    defp uncertain,
      do:
        {:error, %Error{category: :unknown, operation: :embedded, evidence: :dispatch_uncertain}}

    defp failure,
      do:
        {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}, empty(),
         nil}

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation),
      do: operation in [:dispose_partial_branch, :resolve_partial_branch_disposal]

    def pin(context, _), do: {:ok, context}

    def assign(context, record) do
      {:ok, identity} = NativeGrowth.current_identity(record)
      {:ok, history} = NativeGrowth.transitions(record)

      {:ok,
       %{
         context
         | assignment: record.backend_assignment,
           spec: record.spec,
           profile: record.spec.profile,
           name: record.machine_name,
           identity: identity,
           history: history
       }}
    end

    def invoke(context, operation, [parent, child], budget),
      do:
        EmbeddedPartialBranchDisposal.coordinate(
          context,
          operation,
          parent,
          child,
          budget,
          fn ctx, request, b -> GenServer.call(ctx.server, {:call, ctx, request, b, child}) end
        )
  end

  defp fixture(mode \\ :normal, material \\ :held, timeout \\ 1000, transfer \\ 262_144) do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = prepare_fixture(store, mode, material)
    epoch = get_in(metadata.publication, ~w(change child_origin intent epoch))
    epoch = if mode == :wrong_proof_epoch, do: String.duplicate("0", 32), else: epoch
    authority = start_supervised!({Agent, fn -> nil end})

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           epoch: epoch,
           frozen: false,
           store: store,
           mode: mode,
           metadata: metadata,
           child: child
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: peer,
      pinned: true,
      epoch: if(mode == :stale_epoch, do: String.duplicate("0", 32), else: epoch)
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: parent.worker_id,
      context: context,
      budget: %Budget{
        timeout_ms: timeout,
        max_request_bytes: transfer,
        max_response_bytes: if(mode == :response_limit, do: 1024, else: transfer)
      }
    }

    target = %Target{
      kind: :embedded,
      id: parent.worker_id,
      connection: reference,
      draining: mode == :draining
    }

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority, parent.worker_id, mode}},
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

    {runtime, store, parent, child, usage, authority, context}
  end

  defp prepare_fixture(store, :unacknowledged, material) do
    {parent, child, completion, usage} =
      NativeUnbootedBranchDisposalContract.prepare(Memory, store, material == :held)

    {:ok, child} =
      NativePartialBranchCollectionContract.accept(
        Memory,
        store,
        parent,
        child,
        child.version,
        1103
      )

    {Contract.fetch(Memory, store, parent), child,
     %{publication: completion.completion.publication, source: completion.source, release: nil},
     usage}
  end

  defp prepare_fixture(store, _, material), do: Contract.prepare(Memory, store, material)

  defp dispose(runtime, child, version \\ nil),
    do:
      Branches.dispose_partial(runtime, ManagedMachine.key(child), version || child.version,
        quiesced: true
      )

  defp resolve(runtime, child),
    do:
      Branches.resolve(runtime, ManagedMachine.key(child), quiesced: true, disposition: :deleted)

  defp calls(acc \\ []) do
    receive do
      {:native_call, _, _, _, _, _, _} = call -> calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for material <- [:held, :pre_release, :initial_release, :explicit_release] do
    test "#{material} public disposal fences the accepted request and paired commit without synthesizing a child" do
      {runtime, store, parent, child, usage, authority, context} =
        fixture(:normal, unquote(material))

      collection = child.branch.native_authority.partial_collection
      assert {:ok, disposed} = dispose(runtime, child)
      assert disposed.state == :deleted and disposed.branch.state == :disposed
      assert disposed.created_machine == nil and disposed.observed_machine == nil
      assert disposed.branch.native_authority.completion == nil
      assert disposed.branch.native_authority.partial_collection == collection
      assert disposed.branch.native_authority.partial_disposal.proof.completion == "deleted"
      assert_receive {:store_write, :branch_advance, true}
      assert_receive {:store_write, :branch_resolve, true}
      assert_receive {:quiesce, :ok}
      assert_receive :modeled_delete_entry
      events = calls()
      assert Enum.map(events, &elem(&1, 1)) == ~w(dispose_partial_branch inspect)

      for {_, _, frozen, quiesced, epoch, _, budget} <- events do
        assert frozen and quiesced and epoch == context.epoch

        assert budget.timeout_ms <= 1000 and budget.max_request_bytes <= 26 * 1024 and
                 budget.max_response_bytes <= 64 * 1024
      end

      {_, _, _, _, _, request, _} = hd(events)
      assert request["request"] == disposed.branch.native_authority.partial_disposal.request
      assert Contract.fetch(Memory, store, parent).branch_children == %{child.id => false}
      assert Contract.fetch(Memory, store, parent).active_branch == nil
      assert {:ok, actual} = Memory.usage(store, parent.worker_id)

      assert actual ==
               Map.merge(usage, Profile.resources(child.spec.profile), fn _, total, ordinary ->
                 total - ordinary
               end)

      assert {:ok, <<"smolbox-record-v45", 0, _::binary>>} = Codec.encode(disposed)
      assert Agent.get(authority, & &1) == nil and Process.alive?(context.server)
      assert {:ok, ^disposed} = dispose(runtime, child)
      assert {:ok, ^disposed} = dispose(runtime, disposed)
      assert {:ok, ^disposed} = resolve(runtime, disposed)

      assert {:ok, ^disposed} =
               Branches.collect_partial(runtime, ManagedMachine.key(disposed), collection.version,
                 quiesced: true
               )

      assert calls() == []
      refute_receive {:quiesce, _}
    end
  end

  for mode <- [:accept_failure, :stale_epoch, :stale_before_accept] do
    test "#{mode} cannot accept or dispatch partial disposal" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, _} = dispose(runtime, child)
      assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert calls() == [] and Agent.get(authority, & &1) == nil
      refute_receive :modeled_delete_entry
    end
  end

  for mode <- [:wrong_source, :wrong_proof_epoch, :stale_child, :store_failure, :output, :cursor] do
    test "#{mode} retains the exact accepted action and ordinary dependency/backing reservations" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = dispose(runtime, child)
      pending = Contract.fetch(Memory, store, child)
      assert pending.branch.state == :disposal_pending
      assert pending.branch.native_authority.partial_disposal.proof == nil

      assert pending.branch.native_authority.partial_collection ==
               child.branch.native_authority.partial_collection

      assert pending.reservation == child.reservation
      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
    end
  end

  for mode <- [:lost_disposal, :lost_source] do
    test "#{mode} retries original observation and never offers deletion again" do
      {runtime, store, parent, child, usage, _, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = dispose(runtime, child)
      pending = Contract.fetch(Memory, store, child)
      saved = pending.branch.native_authority.partial_disposal
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Enum.count(calls(), &(elem(&1, 1) == "dispose_partial_branch")) == 1
      assert_receive :modeled_delete_entry
      assert {:ok, disposed} = resolve(runtime, pending)
      assert disposed.branch.native_authority.partial_disposal.request == saved.request
      assert Enum.map(calls(), &elem(&1, 1)) == ~w(resolve_partial_branch_disposal inspect)
      refute_receive :modeled_delete_entry
    end
  end

  test "uncertain original observation cannot fall through to native deletion" do
    {runtime, store, parent, child, usage, _, _} = fixture(:unknown_observation)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1105)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = dispose(runtime, pending)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(resolve_partial_branch_disposal)
    refute_receive :modeled_delete_entry
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "an accepted unentered action observes first and offers only the same bounded request" do
    {runtime, store, parent, child, _, _, _} = fixture()
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1105)
    assert {:ok, disposed} = dispose(runtime, pending)
    events = calls()

    assert Enum.map(events, &elem(&1, 1)) ==
             ~w(resolve_partial_branch_disposal dispose_partial_branch inspect)

    assert elem(Enum.at(events, 0), 5)["request"] == elem(Enum.at(events, 1), 5)["request"]

    assert disposed.branch.native_authority.partial_disposal.request ==
             pending.branch.native_authority.partial_disposal.request

    stages = Enum.reject(events, &(elem(&1, 1) == "inspect"))
    assert Enum.sum(Enum.map(stages, &elem(&1, 6).max_request_bytes)) <= 262_144
    assert Enum.sum(Enum.map(stages, &elem(&1, 6).max_response_bytes)) <= 262_144
  end

  test "positive resolved absence preserves its provenance without SDK dispatch" do
    {runtime, store, parent, child, _, _, _} = fixture(:resolved_absent)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1105)
    assert {:ok, disposed} = dispose(runtime, pending)
    assert disposed.branch.native_authority.partial_disposal.proof.completion == "resolved_absent"
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(resolve_partial_branch_disposal inspect)
    refute_receive :modeled_delete_entry
  end

  test "definitive rejection retains not-dispatched evidence and the accepted action" do
    {runtime, store, parent, child, usage, _, _} = fixture(:not_dispatched)
    assert {:error, %Error{evidence: :not_dispatched}} = dispose(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.proof ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    refute_receive :modeled_delete_entry
  end

  test "retained disposal is available while draining" do
    {runtime, _, _, child, _, _, _} = fixture(:draining)
    assert {:ok, _} = resolve(runtime, child)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(dispose_partial_branch inspect)
  end

  test "invalid options and stale versions cannot contact the helper" do
    {runtime, store, _, child, _, _, _} = fixture()

    assert {:error, _} =
             Branches.dispose_partial(runtime, ManagedMachine.key(child), child.version, [])

    assert {:error, _} = dispose(runtime, child, child.version + 100)
    assert Contract.fetch(Memory, store, child) == child
    assert calls() == []
    refute_receive {:quiesce, _}
  end

  test "a spent transfer allowance cannot dispatch native disposal" do
    {runtime, store, parent, child, usage, _, _} = fixture(:normal, :held, 1000, 1024)

    assert {:error, %Error{category: :output_limit, evidence: :not_dispatched}} =
             dispose(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.proof ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert calls() == []
  end

  test "an unacknowledged collection cannot fall through to other retirement or disposal paths" do
    {runtime, store, parent, child, usage, _, _} = fixture(:unacknowledged)
    assert {:error, %Error{category: :unsupported_capability}} = dispose(runtime, child)
    assert {:error, %Error{category: :unsupported_capability}} = resolve(runtime, child)
    assert Contract.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert calls() == []
    refute_receive {:quiesce, _}
  end

  test "an expired adapter deadline and changed pinned platform cannot dispatch disposal" do
    {_, store, parent, child, _, _, context} = fixture()
    {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1105)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)

    budget = %Budget{
      timeout_ms: 1000,
      max_request_bytes: 26 * 1024,
      max_response_bytes: 64 * 1024
    }

    callback = fn _, _, _ -> flunk("unqualified disposal dispatched") end

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             EmbeddedPartialBranchDisposal.coordinate(
               context,
               :dispose_partial_branch,
               parent,
               pending,
               budget,
               callback,
               System.monotonic_time(:millisecond) - 1
             )

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             EmbeddedPartialBranchDisposal.coordinate(
               %{context | config: %{context.config | platform: :linux}},
               :dispose_partial_branch,
               parent,
               pending,
               budget,
               callback
             )

    assert Contract.fetch(Memory, store, child) == pending
  end

  test "an exhausted proof allowance remains uncertain and cannot publish disposal or inspect source" do
    {runtime, store, parent, child, usage, _, _} = fixture(:response_limit)

    assert {:error, %Error{category: :output_limit, evidence: :dispatch_uncertain}} =
             dispose(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.proof ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(dispose_partial_branch)
  end
end
