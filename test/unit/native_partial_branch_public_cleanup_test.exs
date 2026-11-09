defmodule SmolBox.NativePartialBranchPublicCleanupTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine, Profile}

  alias SmolBox.Backend.{
    Budget,
    EmbeddedContext,
    EmbeddedPartialBranchCleanup,
    EmbeddedPartialBranchDisposal,
    Reference
  }

  alias SmolBox.Embedded.{
    Config,
    NativeGrowth,
    NativePartialBranchCleanup,
    PartialBranchCleanupCandidate,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded,
    SDKIdentity
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativeBranchBackingContract,
    NativePartialBranchBackingContract,
    NativePartialBranchCleanupContract,
    NativePartialBranchCleanupResolutionContract,
    NativePartialBranchCollectionContract,
    NativePartialBranchDisposalContract,
    NativePartialBranchRetirementContract,
    NativeUnbootedBranchDisposalContract
  }

  alias NativePartialBranchCleanupContract, as: Contract
  alias SmolBox.Store.Contract, as: StoreContract

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
      if operation in [:branch_advance, :branch_resolve],
        do: write(store, observer, authority, worker, mode, operation, args),
        else: Memory.machine(store, operation, args)
    end

    defp write(store, observer, authority, worker, mode, operation, args) do
      caller = self()
      held = Agent.get(authority, &(&1 == {worker, caller}))
      send(observer, {:store_write, operation, held})

      if held and permitted?(operation, mode) do
        result = Memory.machine(store, operation, args)
        delay(operation, mode)
        result
      else
        {:error, %Error{category: :store, operation: :branch}}
      end
    end

    defp permitted?(:branch_resolve, {:unneeded, %{commit: :failure}}), do: false
    defp permitted?(:branch_advance, :accept_failure), do: false

    defp permitted?(:branch_resolve, mode) when mode in [:store_failure, :terminal_store_failure],
      do: false

    defp permitted?(_, _), do: true
    defp delay(:branch_resolve, {:unneeded, %{commit: :late}}), do: Process.sleep(2000)
    defp delay(:branch_advance, :late_accept), do: Process.sleep(2000)

    defp delay(:branch_resolve, mode) when mode in [:late_commit, :terminal_late_commit],
      do: Process.sleep(2000)

    defp delay(_, _), do: :ok
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, Map.merge(state, %{cleaned: nil, observations: 0})}

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

      if match?({:unneeded, _}, state.mode),
        do: send(state.observer, {:native_reply, request["operation"], response})

      {:reply, response, state}
    end

    defp respond(_, %{"operation" => "qualify_partial_branch_cleanup"}, child, state) do
      qualification(child, state)
    end

    defp respond(
           _,
           %{"operation" => "cleanup_partial_branch_disposal"},
           child,
           %{mode: {:unneeded, %{cleanup: :wrong_outcome}}} = state
         ) do
      result =
        NativePartialBranchCleanupResolutionContract.result(child, state.metadata, "deleted")

      {resolution_response(result, nil, false), state}
    end

    defp respond(
           context,
           %{"operation" => "cleanup_partial_branch_disposal"} = request,
           child,
           %{mode: {:unneeded, options}} = state
         ) do
      if options[:cleanup] == :removal do
        {reply, next} = respond(context, request, child, %{state | mode: :normal})
        {reply, %{next | mode: state.mode}}
      else
        if options[:stale_child],
          do:
            Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])

        reply = refusal(options[:cleanup])
        {reply, state}
      end
    end

    defp respond(
           _,
           %{"operation" => "resolve_partial_branch_cleanup", "request" => request},
           child,
           %{mode: {:unneeded, options}} = state
         ) do
      if options[:resolution] == :refused do
        {failure(), state}
      else
        result =
          state.cleaned ||
            NativePartialBranchCleanupResolutionContract.result(
              child,
              state.metadata,
              options[:provenance] || "deleted"
            )

        true = result.proof.request == request
        if state.cleaned == nil, do: send(state.observer, :modeled_unneeded_acknowledgement)

        {resolution_response(result, options[:resolution], state.cleaned == nil),
         %{state | cleaned: result}}
      end
    end

    defp respond(
           context,
           %{"operation" => "inspect"} = request,
           child,
           %{mode: {:unneeded, options}} = state
         ) do
      {response, next} =
        respond(context, request, child, %{state | mode: options[:source] || :normal})

      {response, %{next | mode: state.mode}}
    end

    defp respond(
           _,
           %{"operation" => "cleanup_partial_branch_disposal"},
           _,
           %{mode: :not_dispatched} = state
         ),
         do: {failure(), state}

    defp respond(
           _,
           %{"operation" => "cleanup_partial_branch_disposal", "request" => request},
           child,
           state
         ) do
      if state.cleaned != nil, do: true = state.cleaned.proof.request == request
      result = state.cleaned || Contract.result(child, state.metadata)
      if state.cleaned == nil, do: send(state.observer, :modeled_removal_entry)

      if state.mode == :stale_child,
        do:
          Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])

      response = cleanup_response(result, state)
      {response, %{state | cleaned: result}}
    end

    defp respond(context, %{"operation" => "inspect"}, _, state) do
      pid = state.metadata.source.backend_identity.pid_identity
      pid = if state.mode == :wrong_source, do: [999, 999], else: pid

      response =
        if state.mode in [:lost_source, :terminal_source_lost] and state.observations == 0,
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

    defp refusal(:uncertain), do: uncertain()

    defp refusal(:direct),
      do: {:error, %Error{category: :unknown, operation: :embedded, evidence: :not_dispatched}}

    defp refusal(:ownership),
      do:
        {:ok, %{"result" => "error", "code" => "ownership", "dispatch" => "not_dispatched"},
         empty(), nil}

    defp refusal(:output), do: {:ok, elem(failure(), 1), %{empty() | stdout: "unexpected"}, nil}
    defp refusal(:malformed), do: {:ok, Map.put(elem(failure(), 1), "extra", true), empty(), nil}
    defp refusal(_), do: failure()

    defp resolution_response(_, :lost, true), do: uncertain()

    defp resolution_response(result, :wrong_request, _) do
      request = Map.put(result.proof.request, "operation_id", "crossed-unneeded-cleanup")

      request =
        Map.put(request, "request_sha256", PartialBranchDisposalCleanup.request_digest(request))

      proof = %{result.proof | request: request}

      proof = %{
        proof
        | proof_sha256:
            PartialBranchDisposalCleanupUnneeded.proof_digest(
              PartialBranchDisposalCleanupUnneeded.to_wire(proof)
            )
      }

      resolution_response(%{result | proof: proof}, nil, false)
    end

    defp resolution_response(result, :removal_proof, _) do
      wire = PartialBranchDisposalCleanupUnneeded.to_wire(result.proof)
      wire = Map.put(wire, "proof_sha256", PartialBranchDisposalCleanup.proof_digest(wire))
      true = PartialBranchDisposalCleanup.valid?(wire)
      {:ok, %{"result" => "partial_branch_disposal_cleaned", "proof" => wire}, empty(), nil}
    end

    defp resolution_response(result, :output, _) do
      {:ok, outcome, _, nil} = resolution_response(result, nil, false)
      {:ok, outcome, %{empty() | stdout: "unexpected"}, nil}
    end

    defp resolution_response(result, :cursor, _) do
      {:ok, outcome, out, nil} = resolution_response(result, nil, false)
      {:ok, outcome, out, "unexpected"}
    end

    defp resolution_response(result, _, _),
      do:
        {:ok,
         %{
           "result" => "partial_branch_cleanup_unneeded",
           "proof" => PartialBranchDisposalCleanupUnneeded.to_wire(result.proof)
         }, empty(), nil}

    defp qualification(_, %{mode: :qualification_refused} = state), do: {failure(), state}
    defp qualification(_, %{mode: :qualification_lost} = state), do: {uncertain(), state}

    defp qualification(_, %{mode: :qualification_unknown} = state),
      do:
        {{:error, %Error{category: :unknown, operation: :branch, evidence: :not_dispatched}},
         state}

    defp qualification(child, state) do
      if state.mode == :qualification_slow, do: Process.sleep(2000)

      if state.mode == :stale_after_qualification,
        do:
          Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])

      completion = if state.mode == :terminal_deleted, do: "deleted", else: "resolved_absent"
      result = NativePartialBranchDisposalContract.result(child, state.metadata, completion)
      wire = PartialBranchDisposal.to_wire(result.proof)

      if state.mode in [
           :terminal_deleted,
           :terminal_absent,
           :terminal_source_lost,
           :terminal_store_failure,
           :terminal_late_commit
         ] do
        {{:ok, %{"result" => "partial_branch_disposed", "proof" => wire}, empty(), nil}, state}
      else
        candidate = Map.drop(wire, ~w(completion proof_sha256))

        candidate =
          Map.put(
            candidate,
            "proof_sha256",
            PartialBranchCleanupCandidate.proof_digest(candidate)
          )

        candidate =
          if state.mode == :qualification_crossed do
            request = Map.put(candidate["request"], "operation_id", "foreign-disposal")

            request =
              Map.put(request, "request_sha256", PartialBranchDisposal.request_digest(request))

            candidate = Map.put(candidate, "request", request)

            Map.put(
              candidate,
              "proof_sha256",
              PartialBranchCleanupCandidate.proof_digest(candidate)
            )
          else
            candidate
          end

        outcome = %{"result" => "partial_branch_cleanup_candidate", "candidate" => candidate}

        response =
          if state.mode == :qualification_output,
            do: {:ok, outcome, %{empty() | stdout: "unexpected"}, nil},
            else: {:ok, outcome, empty(), nil}

        {response, state}
      end
    end

    defp cleanup_response(_, %{mode: :lost_proof, cleaned: nil}), do: uncertain()

    defp cleanup_response(result, %{mode: :output}) do
      {:ok, outcome, empty, nil} = proof(result)
      {:ok, outcome, %{empty | stdout: "unexpected"}, nil}
    end

    defp cleanup_response(result, %{mode: :cursor}) do
      {:ok, outcome, empty, nil} = proof(result)
      {:ok, outcome, empty, "unexpected"}
    end

    defp cleanup_response(result, %{mode: :legacy_disposal}),
      do:
        {:ok, %{"result" => "partial_branch_disposed", "proof" => result.proof.disposal}, empty(),
         nil}

    defp cleanup_response(result, %{mode: :wrong_request}) do
      changed = Map.put(result.proof.request, "operation_id", "different-cleanup")

      changed =
        Map.put(changed, "request_sha256", PartialBranchDisposalCleanup.request_digest(changed))

      changed = %{result.proof | request: changed}

      changed = %{
        changed
        | proof_sha256:
            PartialBranchDisposalCleanup.proof_digest(
              PartialBranchDisposalCleanup.to_wire(changed)
            )
      }

      proof(%{result | proof: changed})
    end

    defp cleanup_response(result, _), do: proof(result)

    defp proof(result),
      do:
        {:ok,
         %{
           "result" => "partial_branch_disposal_cleaned",
           "proof" => PartialBranchDisposalCleanup.to_wire(result.proof)
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
      do: operation in [:cleanup_partial_branch_disposal, :qualify_partial_branch_cleanup]

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

    def invoke(context, operation, [parent, child], budget) do
      module =
        if operation == :qualify_partial_branch_cleanup,
          do: EmbeddedPartialBranchDisposal,
          else: EmbeddedPartialBranchCleanup

      module.coordinate(
        context,
        operation,
        parent,
        child,
        budget,
        fn ctx, request, b -> GenServer.call(ctx.server, {:call, ctx, request, b, child}) end
      )
    end
  end

  defmodule CleanupOnlyAdapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :cleanup_partial_branch_disposal
    defdelegate pin(context, budget), to: Adapter
    defdelegate assign(context, record), to: Adapter
    defdelegate invoke(context, operation, args, budget), to: Adapter
  end

  # Happy paths allow scheduling under concurrent model suites. Deadline cases
  # supply their own explicit short budgets below.
  defp fixture(mode \\ :normal, material \\ :held, timeout \\ 5000, transfer \\ 262_144) do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = prepare_fixture(store, mode, material)
    options = resolution_options(mode)
    epoch = fixture_epoch(metadata, mode, options)
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

    transfer = if is_function(transfer, 1), do: transfer.(child), else: transfer

    native_config = fixture_native_config(mode, options)

    context = %EmbeddedContext{
      config: native_config,
      server: peer,
      pinned: true,
      epoch: if(mode == :stale_epoch, do: String.duplicate("0", 32), else: epoch)
    }

    reference = %Reference{
      adapter: if(mode == :cleanup_only, do: CleanupOnlyAdapter, else: Adapter),
      kind: :embedded,
      id: parent.worker_id,
      context: context,
      budget: %Budget{
        timeout_ms: timeout,
        max_request_bytes: transfer,
        max_response_bytes:
          options[:response_bytes] || if(mode == :response_limit, do: 1024, else: transfer)
      }
    }

    target = %Target{
      kind: :embedded,
      id: parent.worker_id,
      connection: reference,
      draining: mode == :draining or options[:draining] == true
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

  defp resolution_options({:unneeded, options}), do: options
  defp resolution_options(_), do: %{}

  defp fixture_epoch(metadata, mode, options) do
    if mode == :wrong_proof_epoch or options[:wrong_epoch],
      do: String.duplicate("0", 32),
      else: get_in(metadata.publication, ~w(change child_origin intent epoch))
  end

  defp fixture_native_config(mode, options) do
    config = struct(Config, platform: if(mode == :wrong_platform, do: :linux, else: :macos))
    if match?({:unneeded, _}, mode), do: future_resolution_config(config, options), else: config
  end

  # Explicit future in-process descriptor only. It cannot approve or launch a package.
  defp future_resolution_config(config, options) do
    revision = "9f446ae00219148ca4a703914f44a8e2fab11655"
    sdk = SDKIdentity.implemented("1.22.0", revision)

    sdk =
      put_in(sdk, ~w(feature_versions branches), if(options[:branches] == false, do: 0, else: 1))

    sdk =
      if options[:feature] == false,
        do: sdk,
        else: put_in(sdk, ~w(feature_versions partial_cleanup_resolution), 1)

    %{
      config
      | package_identity: %{"engine_version" => "0.2.0", "smolvm_revision" => revision},
        sdk_identity: sdk
    }
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

  defp prepare_fixture(store, :unaccepted_disposal, material),
    do: NativePartialBranchDisposalContract.prepare(Memory, store, material)

  defp prepare_fixture(store, _, material), do: Contract.prepare(Memory, store, material)

  defp cleanup(runtime, child, version \\ nil),
    do:
      Branches.cleanup_partial(runtime, ManagedMachine.key(child), version || child.version,
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
    test "#{material} public cleanup fences accepted action and paired commit without SDK disposal or a child Machine" do
      {runtime, store, parent, child, usage, authority, context} =
        fixture(:normal, unquote(material))

      original = child.branch.native_authority.partial_disposal
      collection = child.branch.native_authority.partial_collection
      assert {:ok, disposed} = cleanup(runtime, child)
      saved = disposed.branch.native_authority.partial_disposal
      assert_history(disposed, saved, original, collection)
      assert_receive {:store_write, :branch_advance, true}
      assert_receive {:store_write, :branch_resolve, true}
      assert_receive {:quiesce, :ok}
      assert_receive :modeled_removal_entry
      events = calls()

      assert Enum.map(events, &elem(&1, 1)) ==
               ~w(qualify_partial_branch_cleanup cleanup_partial_branch_disposal inspect)

      for {_, _, frozen, quiesced, epoch, _, budget} <- events do
        assert frozen and quiesced and epoch == context.epoch

        assert budget.timeout_ms <= 5000 and budget.max_request_bytes <= 32 * 1024 and
                 budget.max_response_bytes <= 96 * 1024
      end

      assert elem(hd(events), 5)["request"] == original.request
      assert elem(Enum.at(events, 1), 5)["request"] == saved.cleanup.request
      assert Contract.fetch(Memory, store, parent).branch_children == %{child.id => false}
      assert Contract.fetch(Memory, store, parent).active_branch == nil
      assert {:ok, actual} = Memory.usage(store, parent.worker_id)

      assert actual ==
               Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

      assert {:ok, <<"smolbox-record-v48", 0, _::binary>>} = Codec.encode(disposed)
      assert Agent.get(authority, & &1) == nil and Process.alive?(context.server)
      assert {:ok, ^disposed} = cleanup(runtime, child)
      assert {:ok, ^disposed} = cleanup(runtime, disposed)
      assert {:ok, ^disposed} = resolve(runtime, disposed)

      assert {:ok, ^disposed} =
               Branches.dispose_partial(runtime, ManagedMachine.key(disposed), original.version,
                 quiesced: true
               )

      assert {:ok, ^disposed} =
               Branches.collect_partial(runtime, ManagedMachine.key(disposed), collection.version,
                 quiesced: true
               )

      assert calls() == []
      refute_receive {:quiesce, _}
    end
  end

  for mode <- [
        :accept_failure,
        :stale_epoch,
        :stale_before_accept,
        :wrong_platform,
        :wrong_proof_epoch
      ] do
    test "#{mode} cannot accept or dispatch cleanup" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, _} = cleanup(runtime, child)

      assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup ==
               nil

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      events = calls()
      assert Enum.all?(events, &(elem(&1, 1) == "qualify_partial_branch_cleanup"))
      assert Agent.get(authority, & &1) == nil
      refute_receive :modeled_removal_entry
    end
  end

  for mode <- [
        :wrong_source,
        :stale_child,
        :store_failure,
        :output,
        :cursor,
        :legacy_disposal,
        :wrong_request
      ] do
    test "#{mode} retains exact accepted cleanup and every reservation after uncertain response" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = cleanup(runtime, child)
      pending = Contract.fetch(Memory, store, child)
      assert pending.branch.state == :disposal_cleanup_pending
      assert pending.branch.native_authority.partial_disposal.cleanup.proof == nil
      assert pending.branch.native_authority.partial_disposal.proof == nil

      assert pending.branch.native_authority.partial_collection ==
               child.branch.native_authority.partial_collection

      assert pending.reservation == child.reservation
      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
    end
  end

  for mode <- [:lost_proof, :lost_source] do
    test "#{mode} retries only the same saved cleanup control and never repeats modeled removal" do
      {runtime, store, parent, child, usage, _, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = cleanup(runtime, child)
      pending = Contract.fetch(Memory, store, child)
      saved = pending.branch.native_authority.partial_disposal.cleanup
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      first = calls()
      assert_receive :modeled_removal_entry

      response =
        if unquote(mode) == :lost_proof,
          do: resolve(runtime, pending),
          else: cleanup(runtime, pending, saved.version)

      assert {:ok, disposed} = response
      second = calls()
      assert Enum.map(second, &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal inspect)
      assert elem(Enum.at(first, 1), 5) == elem(hd(second), 5)
      assert disposed.branch.native_authority.partial_disposal.cleanup.request == saved.request
      refute_receive :modeled_removal_entry
    end
  end

  test "already accepted cleanup freezes its saved version across retry admission" do
    {runtime, store, parent, child, _, _, _} = fixture()
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    saved = pending.branch.native_authority.partial_disposal.cleanup
    assert {:ok, disposed} = cleanup(runtime, pending, saved.version)
    assert disposed.branch.native_authority.partial_disposal.cleanup.request == saved.request
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal inspect)
  end

  test "definitive rejection preserves not-dispatched evidence the accepted request and charges" do
    {runtime, store, parent, child, usage, _, _} = fixture(:not_dispatched)
    assert {:error, %Error{evidence: :not_dispatched}} = cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup.proof ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    refute_receive :modeled_removal_entry
  end

  test "cleanup remains available during draining" do
    {runtime, _, _, child, _, _, _} = fixture(:draining)
    assert {:ok, _} = cleanup(runtime, child)

    assert Enum.map(calls(), &elem(&1, 1)) ==
             ~w(qualify_partial_branch_cleanup cleanup_partial_branch_disposal inspect)
  end

  test "invalid options versions or absent disposal cannot contact the helper" do
    {runtime, store, _, child, _, _, _} = fixture(:unaccepted_disposal)
    assert {:error, _} = cleanup(runtime, child)

    assert {:error, _} =
             Branches.cleanup_partial(runtime, ManagedMachine.key(child), child.version, [])

    assert {:error, _} = cleanup(runtime, child, child.version + 100)

    for version <- [nil, 0, -1, 1.0, 9_007_199_254_740_992] do
      assert {:error, _} =
               Branches.cleanup_partial(runtime, ManagedMachine.key(child), version,
                 quiesced: true
               )
    end

    assert Contract.fetch(Memory, store, child) == child
    assert calls() == []
    refute_receive {:quiesce, _}
  end

  test "unacknowledged collection cannot create cleanup authority" do
    {runtime, store, parent, child, usage, _, _} = fixture(:unacknowledged)
    assert {:error, %Error{category: :unsupported_capability}} = cleanup(runtime, child)
    assert Contract.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert calls() == []
    refute_receive {:quiesce, _}
  end

  test "insufficient request allowance cannot dispatch a cleanup control" do
    {runtime, store, parent, child, usage, _, _} = fixture(:normal, :held, 1000, 1024)

    assert {:error, %Error{category: :output_limit, evidence: :not_dispatched}} =
             cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert calls() == []
  end

  test "exhausted response allowance is uncertain and cannot inspect source or commit cleanup" do
    {runtime, store, parent, child, usage, _, _} = fixture(:response_limit)

    assert {:error, %Error{category: :output_limit, evidence: :dispatch_uncertain}} =
             cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup)
  end

  test "expired adapter deadline changed platform and wrong parent context cannot dispatch" do
    {_, _, _, _, _, _, context} = fixture()
    store = start_supervised!({Memory, []}, id: :adapter_store)
    {parent, child, _, _} = Contract.prepare(Memory, store, :held)
    {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)

    budget = %Budget{
      timeout_ms: 5000,
      max_request_bytes: 32 * 1024,
      max_response_bytes: 96 * 1024
    }

    callback = fn _, _, _ -> flunk("invalid cleanup dispatched") end

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             EmbeddedPartialBranchCleanup.coordinate(
               context,
               :cleanup_partial_branch_disposal,
               parent,
               pending,
               budget,
               callback,
               System.monotonic_time(:millisecond) - 1
             )

    for changed <- [
          %{context | config: %{context.config | platform: :linux}},
          %{context | quiesced: false},
          %{context | name: "other-source"}
        ] do
      assert {:error, %Error{evidence: :not_dispatched}} =
               EmbeddedPartialBranchCleanup.coordinate(
                 changed,
                 :cleanup_partial_branch_disposal,
                 parent,
                 pending,
                 budget,
                 callback
               )
    end
  end

  defp assert_history(disposed, saved, original, collection) do
    assert saved.request == original.request and saved.version == original.version
    assert saved.proof.completion == "resolved_absent"
    assert saved.cleanup.request["disposal_request"] == original.request

    assert saved.cleanup.proof.disposal ==
             PartialBranchDisposal.to_wire(saved.proof)

    assert disposed.state == :deleted and disposed.branch.state == :disposed
    assert disposed.created_machine == nil and disposed.observed_machine == nil
    assert disposed.branch.native_authority.completion == nil
    assert disposed.branch.native_authority.partial_collection == collection
  end

  test "late durable acceptance preserves its grant and charges without native IO" do
    {runtime, store, parent, child, usage, authority, _} = fixture(:late_accept, :held, 1500)

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             cleanup(runtime, child)

    pending = Contract.fetch(Memory, store, child)
    assert pending.branch.state == :disposal_cleanup_pending
    assert pending.branch.native_authority.partial_disposal.cleanup.proof == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup)
    assert Agent.get(authority, & &1) == nil
  end

  test "late positive store acknowledgement is uncertain but its saved proof returns without helper IO" do
    {runtime, store, _, child, _, authority, _} = fixture(:late_commit, :held, 1500)

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
             cleanup(runtime, child)

    completed = Contract.fetch(Memory, store, child)
    assert completed.branch.state == :disposed and completed.reservation == nil
    assert completed.branch.native_authority.partial_disposal.cleanup.proof != nil
    _ = calls()
    assert {:ok, ^completed} = cleanup(runtime, child)
    assert calls() == [] and Agent.get(authority, & &1) == nil
  end

  test "adapter proof expiry keeps uncertainty and never inspects source after its captured deadline" do
    {_, store, parent, child, _, _, context} = fixture()
    {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)
    result = Contract.result(pending, :sys.get_state(context.server).metadata)

    budget = %Budget{
      timeout_ms: 5000,
      max_request_bytes: 32 * 1024,
      max_response_bytes: 96 * 1024
    }

    deadline = System.monotonic_time(:millisecond) + 1500

    callback = fn _, request, _ ->
      assert request["operation"] == "cleanup_partial_branch_disposal"
      Process.sleep(2000)

      {:ok,
       %{
         "result" => "partial_branch_disposal_cleaned",
         "proof" => PartialBranchDisposalCleanup.to_wire(result.proof)
       }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
             EmbeddedPartialBranchCleanup.coordinate(
               context,
               :cleanup_partial_branch_disposal,
               parent,
               pending,
               budget,
               callback,
               deadline
             )

    assert Contract.fetch(Memory, store, child) == pending
  end

  for mode <- [:normal, :terminal_absent, :terminal_deleted] do
    test "#{mode} saved disposition survives retirement and backing closeout without helper IO" do
      {runtime, store, parent, child, _, authority, _} = fixture(unquote(mode))
      assert {:ok, disposed} = cleanup(runtime, child)
      saved = disposed.branch.native_authority.partial_disposal
      version = if saved.cleanup, do: saved.cleanup.version, else: child.version
      _ = calls()
      assert_receive {:quiesce, :ok}
      parent = Contract.fetch(Memory, store, parent)
      proof = NativePartialBranchRetirementContract.proof(disposed)

      assert {:ok, retired} =
               NativePartialBranchRetirementContract.advance(
                 Memory,
                 store,
                 parent,
                 disposed,
                 proof,
                 1500
               )

      parent = Contract.fetch(Memory, store, parent)

      assert {:ok, deleting} =
               Memory.machine(store, :request, [
                 ManagedMachine.key(parent),
                 :delete,
                 parent.version,
                 1501
               ])

      assert {:ok, source} =
               Memory.machine(store, :write, [
                 ManagedMachine.key(parent),
                 StoreContract.guard(deleting),
                 [
                   state: :deleted,
                   operation: nil,
                   phase: nil,
                   operation_deadline_ms: nil,
                   absence_at_ms: 1502
                 ],
                 1502
               ])

      assert {:ok, pending} =
               NativeBranchBackingContract.accept(Memory, store, source, retired, 1503)

      source = Contract.fetch(Memory, store, source)

      backing =
        NativePartialBranchBackingContract.proof(pending.branch.native_authority.backing.request)

      assert {:ok, closed} =
               NativeBranchBackingContract.complete_proof(
                 Memory,
                 store,
                 source,
                 pending,
                 backing,
                 1504
               )

      assert {:ok, ^closed} = cleanup(runtime, closed, version)
      assert {:ok, ^closed} = resolve(runtime, closed)
      assert closed.branch.native_authority.partial_disposal == saved
      assert calls() == [] and Agent.get(authority, & &1) == nil
      refute_receive {:quiesce, _}
    end
  end

  for material <- [:held, :pre_release, :initial_release, :explicit_release],
      {mode, completion} <- [terminal_deleted: "deleted", terminal_absent: "resolved_absent"] do
    test "#{material} #{completion} records the original terminal disposal without accepting cleanup" do
      {runtime, store, parent, child, usage, authority, _} =
        fixture(unquote(mode), unquote(material))

      original = child.branch.native_authority.partial_disposal
      assert {:ok, disposed} = cleanup(runtime, child)
      saved = disposed.branch.native_authority.partial_disposal
      assert saved.cleanup == nil and saved.proof.completion == unquote(completion)
      assert saved.request == original.request and saved.version == original.version
      assert saved.completion_version == child.version
      assert disposed.state == :deleted and disposed.branch.state == :disposed
      assert disposed.created_machine == nil and disposed.observed_machine == nil
      assert disposed.reservation == nil

      assert disposed.branch.native_authority.partial_collection ==
               child.branch.native_authority.partial_collection

      events = calls()
      assert Enum.map(events, &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup inspect)
      assert_receive {:store_write, :branch_resolve, true}
      refute_receive {:store_write, :branch_advance, _}
      refute_receive :modeled_removal_entry
      assert Agent.get(authority, & &1) == nil
      assert {:ok, actual} = Memory.usage(store, parent.worker_id)

      assert actual ==
               Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

      assert Contract.fetch(Memory, store, parent).active_branch == nil
      assert {:ok, bytes} = Codec.encode(disposed)
      assert {:ok, ^disposed} = Codec.decode(bytes)

      for version <- [child.version, disposed.version, saved.version] do
        assert {:ok, ^disposed} = cleanup(runtime, disposed, version)
      end

      assert calls() == []

      assert {:error, %Error{category: :stale_version}} =
               cleanup(runtime, disposed, disposed.version + 10)
    end
  end

  for mode <- [
        :qualification_refused,
        :qualification_unknown,
        :qualification_lost,
        :qualification_output,
        :qualification_crossed,
        :stale_after_qualification
      ] do
    test "#{mode} never mints cleanup authority or falls back to SDK disposal" do
      {runtime, store, parent, child, usage, _, _} = fixture(unquote(mode))
      assert {:error, _} = cleanup(runtime, child)
      pending = Contract.fetch(Memory, store, child)

      assert pending.branch.native_authority.partial_disposal ==
               child.branch.native_authority.partial_disposal

      assert pending.branch.state == :disposal_pending and
               pending.reservation == child.reservation

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup)
      refute_receive :modeled_removal_entry
      refute_receive {:store_write, :branch_resolve, _}
    end
  end

  test "qualification expiry cannot create a cleanup action" do
    {runtime, store, parent, child, usage, _, _} = fixture(:qualification_slow, :held, 1500)

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
             cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup)
    refute_receive {:store_write, _, _}
    refute_receive :modeled_removal_entry
  end

  test "positive candidate with insufficient remaining aggregate budget cannot be durably accepted" do
    {runtime, store, parent, child, usage, _, _} = fixture(:normal, :held, 1000, 100_000)

    assert {:error, %Error{category: :output_limit, evidence: :not_dispatched}} =
             cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup)
    refute_receive {:store_write, _, _}
    refute_receive :modeled_removal_entry
  end

  for mode <- [:terminal_source_lost, :terminal_store_failure] do
    test "#{mode} preserves the original pending disposal without a cleanup grant" do
      {runtime, store, parent, child, usage, _, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = cleanup(runtime, child)
      assert Contract.fetch(Memory, store, child) == child
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup inspect)
      refute_receive {:store_write, :branch_advance, _}
      refute_receive :modeled_removal_entry

      if unquote(mode) == :terminal_source_lost do
        assert {:ok, disposed} = cleanup(runtime, child)
        assert disposed.branch.native_authority.partial_disposal.cleanup == nil
        assert Enum.map(calls(), &elem(&1, 1)) == ~w(qualify_partial_branch_cleanup inspect)
      end
    end
  end

  test "late original terminal store acknowledgement returns uncertainty then a cached disposition" do
    {runtime, store, _, child, _, _, _} = fixture(:terminal_late_commit, :held, 1500)

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
             cleanup(runtime, child)

    disposed = Contract.fetch(Memory, store, child)
    assert disposed.branch.native_authority.partial_disposal.cleanup == nil
    assert disposed.branch.native_authority.partial_disposal.proof.completion == "resolved_absent"
    _ = calls()
    assert {:ok, ^disposed} = cleanup(runtime, child)
    assert calls() == []
    refute_receive :modeled_removal_entry
  end

  test "an accepted cleanup cannot be requalified or bypassed by the ordinary terminal reader" do
    {_, store, parent, child, _, _, context} = fixture()
    {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)

    budget = %Budget{
      timeout_ms: 5000,
      max_request_bytes: 26 * 1024,
      max_response_bytes: 64 * 1024
    }

    callback = fn _, _, _ -> flunk("accepted cleanup was requalified") end

    assert {:error, %Error{evidence: :not_dispatched}} =
             EmbeddedPartialBranchDisposal.coordinate(
               context,
               :qualify_partial_branch_cleanup,
               parent,
               pending,
               budget,
               callback
             )

    assert Contract.fetch(Memory, store, child) == pending
  end

  test "fresh cleanup requires advertised qualification before native IO or acceptance" do
    {runtime, store, parent, child, usage, _, _} = fixture(:cleanup_only)

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             cleanup(runtime, child)

    assert Contract.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert calls() == []
    refute_receive {:store_write, _, _}
  end

  test "saved cleanup needs no new qualification capability and preserves smaller configured budgets" do
    {runtime, store, parent, child, _, _, _} = fixture(:cleanup_only, :held, 5000, 16 * 1024)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    saved = pending.branch.native_authority.partial_disposal.cleanup
    assert {:ok, disposed} = cleanup(runtime, pending, saved.version)
    assert disposed.branch.native_authority.partial_disposal.cleanup.request == saved.request
    events = calls()
    assert Enum.map(events, &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal inspect)

    for event <- events do
      budget = elem(event, 6)
      assert budget.max_request_bytes <= 16 * 1024 and budget.max_response_bytes <= 16 * 1024
    end
  end

  test "cleanup and source inspection consume the same encoded byte allowance" do
    {runtime, _, _, child, _, _, _} = fixture()
    assert {:ok, _} = cleanup(runtime, child)
    [qualification, cleanup, inspect] = calls()
    assert elem(qualification, 1) == "qualify_partial_branch_cleanup"
    initial = elem(cleanup, 6)
    remaining = elem(inspect, 6)
    assert initial.max_request_bytes == 32 * 1024
    assert initial.max_response_bytes == 96 * 1024
    assert remaining.max_request_bytes < initial.max_request_bytes
    assert remaining.max_response_bytes < initial.max_response_bytes
    assert remaining.timeout_ms <= initial.timeout_ms
  end

  for material <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ["deleted", "resolved_absent"] do
    test "#{material} #{provenance} public retry closes unnecessary cleanup with its separate acknowledgement" do
      {runtime, store, parent, child, usage, authority, context} =
        fixture({:unneeded, %{provenance: unquote(provenance)}}, unquote(material))

      assert {:error, _} = Config.validate(context.config)
      assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
      saved = pending.branch.native_authority.partial_disposal.cleanup
      assert {:ok, completed} = cleanup(runtime, pending, saved.version)
      disposal = completed.branch.native_authority.partial_disposal

      assert disposal.cleanup.request == saved.request and
               disposal.cleanup.version == saved.version

      assert disposal.cleanup.proof == nil and disposal.cleanup.unneeded != nil
      assert disposal.proof.completion == unquote(provenance)
      assert completed.branch.state == :disposed and completed.state == :deleted

      assert completed.reservation == nil and completed.created_machine == nil and
               completed.observed_machine == nil

      assert completed.branch.native_authority.partial_collection ==
               child.branch.native_authority.partial_collection

      assert Contract.fetch(Memory, store, parent).branch_children == %{child.id => false}
      assert {:ok, actual} = Memory.usage(store, parent.worker_id)

      assert actual ==
               Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

      assert {:ok, <<"smolbox-record-v49", 0, _::binary>> = bytes} = Codec.encode(completed)
      assert {:ok, ^completed} = Codec.decode(bytes)
      events = calls()

      assert Enum.map(events, &elem(&1, 1)) ==
               ~w(cleanup_partial_branch_disposal resolve_partial_branch_cleanup inspect)

      for {_, _, frozen, quiesced, epoch, request, budget} <- events do
        assert frozen and quiesced and epoch == context.epoch

        assert budget.timeout_ms <= 5000 and budget.max_request_bytes <= 32 * 1024 and
                 budget.max_response_bytes <= 96 * 1024

        if request["operation"] != "inspect", do: assert(request["request"] == saved.request)
      end

      assert_pipeline_budget(events, 64 * 1024, 192 * 1024)
      assert_receive {:store_write, :branch_resolve, true}
      assert_receive :modeled_unneeded_acknowledgement
      refute_receive :modeled_removal_entry
      assert Agent.get(authority, & &1) == nil and Process.alive?(context.server)
      assert {:ok, ^completed} = cleanup(runtime, completed, saved.version)
      assert {:ok, ^completed} = cleanup(runtime, completed)
      assert {:ok, ^completed} = resolve(runtime, completed)
      assert calls() == []
    end
  end

  for options <- [
        %{feature: false},
        %{branches: false},
        %{cleanup: :uncertain},
        %{cleanup: :direct},
        %{cleanup: :output},
        %{cleanup: :malformed},
        %{cleanup: :wrong_outcome}
      ] do
    test "#{inspect(options)} cannot start a resolution lookup" do
      {runtime, store, parent, child, usage, _, _} =
        fixture({:unneeded, unquote(Macro.escape(options))})

      assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
      assert {:error, _} = cleanup(runtime, pending)
      assert Enum.map(calls(), &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal)

      assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup ==
               pending.branch.native_authority.partial_disposal.cleanup

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      refute_receive :modeled_removal_entry
      refute_receive :modeled_unneeded_acknowledgement
    end
  end

  for options <- [
        %{resolution: :refused},
        %{resolution: :wrong_request},
        %{resolution: :removal_proof, provenance: "resolved_absent"},
        %{resolution: :output},
        %{resolution: :cursor},
        %{wrong_epoch: true},
        %{response_bytes: 2048},
        %{source: :wrong_source},
        %{stale_child: true},
        %{commit: :failure}
      ] do
    test "#{inspect(options)} preserves the saved action and reservations without another removal offer" do
      {runtime, store, parent, child, usage, authority, _} =
        fixture({:unneeded, unquote(Macro.escape(options))})

      assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
      assert {:error, _} = cleanup(runtime, pending)
      current = Contract.fetch(Memory, store, child)

      assert current.branch.state == :disposal_cleanup_pending and
               current.reservation == pending.reservation

      assert current.branch.native_authority.partial_disposal.cleanup ==
               pending.branch.native_authority.partial_disposal.cleanup

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      events = Enum.map(calls(), &elem(&1, 1))

      assert Enum.take(events, 2) ==
               ~w(cleanup_partial_branch_disposal resolve_partial_branch_cleanup)

      assert Enum.count(events, &(&1 == "cleanup_partial_branch_disposal")) == 1
      refute_receive :modeled_removal_entry
      refute_receive {:store_write, :branch_resolve, false}
      assert Agent.get(authority, & &1) == nil
    end
  end

  for options <- [%{resolution: :lost, cleanup: :ownership}, %{source: :lost_source}] do
    test "#{inspect(options)} retries only original saved acknowledgement history" do
      {runtime, store, parent, child, usage, _, _} =
        fixture({:unneeded, unquote(Macro.escape(options))})

      assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
      assert {:error, %Error{evidence: :dispatch_uncertain}} = cleanup(runtime, pending)
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      _ = calls()
      assert {:ok, completed} = cleanup(runtime, pending)
      assert completed.branch.native_authority.partial_disposal.cleanup.unneeded != nil

      assert Enum.map(calls(), &elem(&1, 1)) ==
               ~w(cleanup_partial_branch_disposal resolve_partial_branch_cleanup inspect)

      refute_receive :modeled_removal_entry
    end
  end

  test "late unneeded commit is uncertain then returns its saved acknowledgement without helper IO" do
    {runtime, store, parent, child, _, _, _} = fixture({:unneeded, %{commit: :late}}, :held, 1500)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = cleanup(runtime, pending)
    completed = Contract.fetch(Memory, store, child)
    assert completed.branch.native_authority.partial_disposal.cleanup.unneeded != nil
    _ = calls()
    assert {:ok, ^completed} = cleanup(runtime, pending)
    assert calls() == []
    refute_receive :modeled_removal_entry
  end

  test "negotiated resolution does not replace actual residual removal" do
    {runtime, store, parent, child, _, _, _} = fixture({:unneeded, %{cleanup: :removal}})
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    assert {:ok, completed} = cleanup(runtime, pending)
    saved = completed.branch.native_authority.partial_disposal.cleanup
    assert saved.proof != nil and saved.unneeded == nil
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal inspect)
    assert_receive :modeled_removal_entry
    refute_receive :modeled_unneeded_acknowledgement
  end

  test "lookup cannot reset the configured byte budget or dispatch a second request after exhaustion" do
    budget = fn child ->
      byte_size(
        Jason.encode!(%{
          "operation" => "cleanup_partial_branch_disposal",
          "request" => child.branch.native_authority.partial_disposal.cleanup.request
        })
      ) + 2048
    end

    # Compute against the accepted shape without introducing another public action.
    transfer = fn child ->
      authority = child.branch.native_authority
      cleanup = NativePartialBranchCleanup.new(authority, child.version, "macos")
      budget.(put_in(child.branch.native_authority.partial_disposal.cleanup, cleanup))
    end

    {runtime, store, parent, child, usage, _, _} =
      fixture({:unneeded, %{}}, :held, 5000, transfer)

    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)

    assert {:error, %Error{category: :output_limit, evidence: :not_dispatched}} =
             cleanup(runtime, pending)

    assert Enum.map(calls(), &elem(&1, 1)) == ~w(cleanup_partial_branch_disposal)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_disposal.cleanup ==
             pending.branch.native_authority.partial_disposal.cleanup

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    refute_receive :modeled_unneeded_acknowledgement
  end

  test "fresh qualification and draining can finish with an unnecessary-cleanup acknowledgement" do
    {runtime, store, _, child, _, _, _} = fixture({:unneeded, %{draining: true}})
    assert {:ok, completed} = cleanup(runtime, child)
    assert completed.branch.native_authority.partial_disposal.cleanup.unneeded != nil

    assert Enum.map(calls(), &elem(&1, 1)) ==
             ~w(qualify_partial_branch_cleanup cleanup_partial_branch_disposal resolve_partial_branch_cleanup inspect)

    assert Contract.fetch(Memory, store, completed) == completed
    refute_receive :modeled_removal_entry
  end

  defp assert_pipeline_budget(events, input, output) do
    replies = native_replies()
    assert length(events) == length(replies)

    assert Enum.reduce(events, 0, fn event, total ->
             total + byte_size(Jason.encode!(elem(event, 5))) + 1024
           end) <= input

    assert Enum.reduce(replies, 0, fn {_, {:ok, outcome, _, _}}, total ->
             total + byte_size(Jason.encode!(outcome)) + 1024
           end) <= output
  end

  defp native_replies(acc \\ []) do
    receive do
      {:native_reply, op, response} -> native_replies([{op, response} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a smaller configured retry budget is preserved across resolution and source observation" do
    {runtime, store, parent, child, _, _, _} = fixture({:unneeded, %{}}, :held, 5000, 32 * 1024)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    assert {:ok, completed} = cleanup(runtime, pending)
    assert completed.branch.native_authority.partial_disposal.cleanup.unneeded != nil
    events = calls()
    assert_pipeline_budget(events, 32 * 1024, 32 * 1024)

    assert Enum.all?(events, fn event ->
             elem(event, 6).max_request_bytes <= 32 * 1024 and
               elem(event, 6).max_response_bytes <= 32 * 1024
           end)

    refute_receive :modeled_removal_entry
  end

  test "the original deadline cannot be reset by a definitive non-dispatch response" do
    {_, store, parent, child, _, _, context} = fixture({:unneeded, %{}})
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)

    budget = %Budget{
      timeout_ms: 5000,
      max_request_bytes: 64 * 1024,
      max_response_bytes: 192 * 1024
    }

    callback = fn _, request, _ ->
      assert request["operation"] == "cleanup_partial_branch_disposal"
      Process.sleep(2000)

      {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             EmbeddedPartialBranchCleanup.coordinate(
               context,
               :cleanup_partial_branch_disposal,
               parent,
               pending,
               budget,
               callback,
               System.monotonic_time(:millisecond) + 1500
             )

    refute_receive :modeled_unneeded_acknowledgement
  end

  test "saved unnecessary-cleanup acknowledgement remains readable after retirement and backing closeout" do
    {runtime, store, parent, child, _, _, _} =
      fixture({:unneeded, %{provenance: "resolved_absent"}})

    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1401)
    assert {:ok, completed} = cleanup(runtime, pending)
    saved = completed.branch.native_authority.partial_disposal
    _ = calls()
    parent = Contract.fetch(Memory, store, parent)
    NativePartialBranchCleanupResolutionContract.close_storage(Memory, store, parent, completed)
    closed = Contract.fetch(Memory, store, child)
    assert closed.branch.native_authority.partial_disposal == saved
    assert {:ok, ^closed} = cleanup(runtime, closed, saved.cleanup.version)
    assert {:ok, ^closed} = cleanup(runtime, closed, saved.cleanup.completion_version)
    assert {:ok, ^closed} = resolve(runtime, closed)
    assert calls() == []
    refute_receive :modeled_removal_entry
  end
end
