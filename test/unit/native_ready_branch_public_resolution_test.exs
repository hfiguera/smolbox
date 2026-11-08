defmodule SmolBox.NativeReadyBranchPublicResolutionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedBranch,
    EmbeddedContext,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{BranchCompletion, Config, NativeGrowth}

  alias SmolBox.Runtime.{Coordinator, NativeAuthority, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativeBranchContract}

  alias NativeBranchContract, as: Contract

  defmodule Clock do
    def now, do: 1400
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({operation, id} = message, {caller, _} = from, state)
        when operation in [:native_acquire, :native_acquire_operation] do
      {:reply, result, next} = Coordinator.handle_call(message, from, state)

      if result == :ok or match?({:ok, _}, result),
        do: Agent.update(state.authority, fn nil -> {id, caller} end)

      {:reply, result, next}
    end

    def handle_call({:native_release, id} = message, {caller, _} = from, state) do
      Agent.update(state.authority, fn {^id, ^caller} -> nil end)
      Coordinator.handle_call(message, from, state)
    end

    def handle_call(message, from, state), do: Coordinator.handle_call(message, from, state)
  end

  defmodule Store do
    def capabilities({store, _, _, _, _}), do: Memory.capabilities(store)

    def claim_worker({store, _, _, _, _}, id, owner, now, lease),
      do: Memory.claim_worker(store, id, owner, now, lease)

    def machine({store, observer, authority, worker, mode}, :branch_resolve = operation, args) do
      caller = self()
      held = Agent.get(authority, &(&1 == {worker, caller}))
      send(observer, {:store_resolution, held})

      if mode == :stale_commit do
        [key | _] = args
        Memory.machine(store, :claim, [key, "owner", 1400, 10_000])
      end

      if held and mode != :store_failure,
        do: Memory.machine(store, operation, args),
        else: {:error, %Error{category: :store, operation: :branch}}
    end

    def machine({store, _, _, _, _}, operation, args), do: Memory.machine(store, operation, args)
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:health, _, state) do
      {:reply,
       {:ok,
        %{
          status: if(state.frozen, do: :reconciling, else: :ready),
          epoch: state.epoch,
          target_id: state.config.id,
          generation: state.config.domain_generation,
          package_identity: state.config.package_identity,
          package_manifest_sha256: state.config.package_manifest_sha256
        }}, state}
    end

    def handle_call({:activate, binding, epoch}, _, state) do
      true = binding == Config.domain_binding(state.config) and epoch == state.epoch
      send(state.observer, :activated_original_owner)
      {:reply, :ok, %{state | frozen: false}}
    end

    def handle_call({:quiesce, epoch}, _, state) do
      result =
        if state.mode != :busy and epoch == state.epoch,
          do: :ok,
          else: {:error, %Error{category: :identity_conflict, operation: :embedded}}

      send(state.observer, {:quiesce, result})
      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:observe, context, operation, budget}, _, state) do
      send(
        state.observer,
        {:observe, state.frozen, context.quiesced, context.server, context.epoch, operation,
         budget}
      )

      response = response(operation, state)

      if state.mode == :late, do: Process.sleep(90)
      state = if state.mode == :lost_once, do: %{state | mode: :normal}, else: state

      state =
        if state.mode == :new_epoch_after_child and operation["operation"] == "inspect",
          do: %{state | epoch: String.duplicate("f", 32)},
          else: state

      {:reply, response, state}
    end

    defp response(%{"operation" => "resolve_ready_branch_completion"}, state) do
      completion = BranchCompletion.to_wire(state.result.completion)

      case state.mode do
        :missing ->
          {:ok, %{"result" => "branch_completion_presence", "completion" => nil}, empty(), nil}

        :bare ->
          {:ok, :absent}

        :stream ->
          {:ok, %{"result" => "branch_completion_presence", "completion" => completion},
           %{empty() | stdout: "extra"}, nil}

        :wrong_proof ->
          {:ok,
           %{
             "result" => "branch_completion_presence",
             "completion" => put_in(completion, ~w(child owner_token), String.duplicate("0", 64))
           }, empty(), nil}

        :lost_once ->
          {:error, %Error{category: :unknown, operation: :branch, evidence: :dispatch_uncertain}}

        _ ->
          {:ok, %{"result" => "branch_completion_presence", "completion" => completion}, empty(),
           nil}
      end
    end

    defp response(%{"operation" => "branch_preflight"}, state),
      do: observe(state.result.source, state.mode, :source)

    defp response(%{"operation" => "inspect"}, state),
      do: observe(state.result.child, state.mode, :child)

    defp observe(record, mode, side) do
      response = %{
        "result" => "observed",
        "observation" => %{
          "state" => Atom.to_string(record.state),
          "pid_identity" => record.backend_identity.pid_identity,
          "resources" => %{
            "cpus" => record.cpus,
            "memory_mib" => record.memory_mb,
            "storage_gib" => record.storage_gb,
            "overlay_gib" => record.overlay_gb
          },
          "configuration" => %{
            "network" => %{"enabled" => false, "hosts" => [], "cidrs" => []},
            "ports" => [],
            "backend" => nil
          }
        }
      }

      case {mode, side} do
        {:source_admission, :source} ->
          {:error,
           %Error{
             category: :admission_exhausted,
             operation: :embedded,
             evidence: :not_dispatched
           }}

        {:child_admission, :child} ->
          {:ok, %{"result" => "error", "code" => "overload", "dispatch" => "not_dispatched"},
           empty(), nil}

        {:missing_source, :source} ->
          {:error, %Error{category: :not_found, operation: :branch}}

        {:missing_child, :child} ->
          {:error, %Error{category: :not_found, operation: :branch}}

        {:changed_source, :source} ->
          {:ok, put_in(response, ~w(observation resources cpus), record.cpus + 1), empty(), nil}

        {:stopped_child, :child} ->
          {:ok,
           %{
             response
             | "observation" => %{
                 response["observation"]
                 | "state" => "stopped",
                   "pid_identity" => nil
               }
           }, empty(), nil}

        _ ->
          {:ok, response, empty(), nil}
      end
    end

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :resolve_ready_branch
    def pin(context, _), do: {:ok, context}

    def assign(context, record) do
      {:ok, identity} = NativeGrowth.current_identity(record)
      {:ok, history} = NativeGrowth.transitions(record)

      {:ok,
       %{
         context
         | assignment: record.backend_assignment,
           identity: identity,
           history: history,
           spec: record.spec,
           profile: record.spec.profile,
           name: record.machine_name
       }}
    end

    def invoke(context, :resolve_ready_branch, [parent, child], budget),
      do:
        EmbeddedBranch.coordinate(
          context,
          :branch_resolve_creation,
          parent,
          child,
          budget,
          &call/3
        )

    defp call(context, operation, budget),
      do: GenServer.call(context.server, {:observe, context, operation, budget})
  end

  defp publish_fixture(store, parent, child, completion, :published) do
    alias SmolBox.Store.NativeCollectedBranchPublicationContract, as: Publication
    assert {:ok, pending} = Publication.accept(Memory, store, parent, child, child.version, 1103)
    parent = Publication.fetch(Memory, store, parent)

    assert {:ok, published} =
             Publication.finish(
               Memory,
               store,
               parent,
               pending,
               Publication.result(pending, completion),
               1104
             )

    {Publication.fetch(Memory, store, parent), published}
  end

  defp publish_fixture(_, parent, child, _, _), do: {parent, child}

  defp fixture(mode \\ :normal, hold \\ true, options \\ []) do
    store = start_supervised!(Memory)
    {parent, child, result} = Contract.prepare(Memory, store, hold)

    assert {:ok, _} =
             Contract.advance(Memory, store, parent, child, :accepted, :dispatching, 1101)

    parent = fetch(store, parent)

    child = fetch(store, child)

    child =
      if options[:cancel] do
        child
      else
        assert {:ok, unknown} =
                 Contract.advance(Memory, store, parent, child, :dispatching, :unknown, 1102)

        unknown
      end

    parent = fetch(store, parent)
    {parent, child} = publish_fixture(store, parent, child, result, mode)
    {:ok, usage} = Memory.usage(store, parent.worker_id)
    epoch = get_in(result.completion.publication, ~w(change child_origin intent epoch))
    authority = start_supervised!({Agent, fn -> nil end})

    native =
      struct(Config,
        platform: :macos,
        id: parent.worker_id,
        domain_generation: parent.backend_assignment.binding.generation,
        package_identity: %{"model" => "original"},
        package_manifest_sha256: String.duplicate("1", 64)
      )

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           config: native,
           epoch: epoch,
           frozen: false,
           mode: mode,
           result: result
         }}
      )

    context = %EmbeddedContext{
      config: native,
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
        timeout_ms: if(mode == :late, do: 50, else: 1000),
        max_request_bytes: 131_072,
        max_response_bytes: 131_072
      }
    }

    worker = %Target{
      kind: :embedded,
      id: parent.worker_id,
      connection: reference,
      domain_binding: Config.domain_binding(native),
      draining: mode == :draining
    }

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority, parent.worker_id, mode}},
      workers: [worker],
      owner: "owner",
      clock: Clock,
      lease_ms: 10_000,
      poll_ms: 20
    }

    frozen = if options[:ready], do: MapSet.new(), else: MapSet.new([parent.worker_id])

    host = %{
      id: Coordinator,
      start:
        {Host, :start_link,
         [
           %{
             config: config,
             authority: authority,
             task_targets: %{},
             native_holders: %{},
             native_frozen: frozen
           }
         ]}
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

    {runtime, store, parent, child, result, usage, authority, worker}
  end

  defp fetch(store, record) do
    {:ok, current} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])
    current
  end

  defp resolve(runtime, child),
    do: Branches.resolve(runtime, ManagedMachine.key(child), quiesced: true, disposition: :keep)

  for hold <- [true, false] do
    test "held=#{hold} original completion recovery retains a completed healthy scan" do
      {runtime, store, parent, child, result, usage, _, worker} =
        fixture(:normal, unquote(hold), ready: true, cancel: true)

      coordinator = SmolBox.Runtime.coordinator(runtime)
      assert NativeAuthority.available?(coordinator, worker.id)
      assert child.branch.state == :dispatching
      assert {:ok, cancelled} = Branches.cancel(runtime, ManagedMachine.key(child))
      assert cancelled.branch.state == :unknown and cancelled.state == :unknown
      assert fetch(store, parent).state == :unknown
      assert fetch(store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, worker.id)
      assert {:ok, saved} = resolve(runtime, child)
      assert saved.branch.native_authority.completion == result.completion
      assert saved.branch.state == if(unquote(hold), do: :held, else: :ready)
      assert fetch(store, parent).state == :running
      assert {:ok, ^usage} = Memory.usage(store, worker.id)
      assert NativeAuthority.activity(coordinator, worker.id) == %{ready: true, held: false}
      assert_received :activated_original_owner
    end
  end

  test "a previously incomplete scan remains fenced after confirmed ready-result recovery" do
    {runtime, _, _, child, _, _, _, worker} = fixture()
    assert {:ok, _} = resolve(runtime, child)
    refute NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)
    refute_received :activated_original_owner
  end

  test "an epoch change after positive observation preserves the committed result without activation" do
    {runtime, store, parent, child, _, _, _, worker} =
      fixture(:new_epoch_after_child, true, ready: true)

    assert {:ok, saved} = resolve(runtime, child)
    assert saved.branch.state == :held and fetch(store, parent).state == :running
    refute NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)
    refute_received :activated_original_owner
  end

  for mode <- [
        :missing,
        :wrong_proof,
        :missing_source,
        :missing_child,
        :store_failure,
        :stale_commit
      ] do
    test "#{mode} cannot restore a formerly healthy scan without confirmed paired recovery" do
      {runtime, store, parent, child, _, usage, _, worker} =
        fixture(unquote(mode), true, ready: true)

      assert {:error, _} = resolve(runtime, child)
      assert fetch(store, parent).active_branch == child.id
      assert fetch(store, child).branch.state == :unknown
      assert {:ok, ^usage} = Memory.usage(store, worker.id)
      refute NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)
      refute_received :activated_original_owner
    end
  end

  test "confirmed original-result recovery preserves persisted worker draining" do
    {runtime, store, _, child, _, _, _, worker} = fixture(:draining, true, ready: true)
    assert {:ok, control} = Memory.worker_control(store, worker.id)

    assert {:ok, draining} =
             Memory.set_worker_mode(store, worker.id, :draining, control.version, Clock.now())

    assert {:ok, _} = resolve(runtime, child)
    assert NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)
    assert {:ok, ^draining} = Memory.worker_control(store, worker.id)
  end

  for hold <- [true, false] do
    test "held=#{hold} ready resolution consumes the stored material publication exactly once" do
      {runtime, store, parent, child, _, _, _, _} = fixture(:published, unquote(hold))
      assert {:ok, ready} = resolve(runtime, child)
      assert ready.branch.state == if(unquote(hold), do: :held, else: :ready)
      assert fetch(store, parent).native_branch_history == parent.native_branch_history

      assert ready.branch.native_authority.collected_publication ==
               child.branch.native_authority.collected_publication

      saved = ready.branch.native_authority.collected_publication

      for version <- [saved.version, saved.completion_version, ready.version] do
        assert {:ok, ^ready} =
                 Branches.publish_collected(runtime, ManagedMachine.key(ready), version,
                   quiesced: true
                 )
      end
    end
  end

  for hold <- [true, false] do
    test "held=#{hold} kept resolution retains one owner and commits only original completion plus current positives" do
      {runtime, store, parent, child, result, usage, authority, worker} =
        fixture(:normal, unquote(hold))

      assert {:ok, saved} = resolve(runtime, child)
      assert saved.branch.state == if(unquote(hold), do: :held, else: :ready)
      assert saved.branch.native_authority.completion == result.completion
      assert saved.created_machine.state == :created

      assert saved.created_machine.backend_identity.receipt ==
               get_in(result.completion.publication, ~w(change child))

      assert saved.observed_machine.state == :running
      assert saved.observed_machine.backend_identity == result.child.backend_identity
      assert fetch(store, parent).active_branch == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert_receive {:quiesce, :ok}

      assert_receive {:observe, true, true, peer, epoch,
                      %{
                        "operation" => "resolve_ready_branch_completion",
                        "request" => request,
                        "quiesced" => true
                      }, first}

      assert request == child.branch.native_authority.request
      assert peer == worker.connection.context.server and epoch == worker.connection.context.epoch

      assert_receive {:observe, true, true, ^peer, ^epoch, %{"operation" => "branch_preflight"},
                      second}

      assert_receive {:observe, true, true, ^peer, ^epoch, %{"operation" => "inspect"}, third}
      assert first.max_request_bytes <= 28 * 1024 and first.max_response_bytes <= 68 * 1024
      assert second.max_request_bytes < first.max_request_bytes
      assert second.max_response_bytes <= 16_384 and third.max_response_bytes <= 16_384
      assert first.timeout_ms >= second.timeout_ms and second.timeout_ms >= third.timeout_ms
      assert_receive {:store_resolution, true}
      assert Agent.get(authority, & &1) == nil
      assert {:ok, <<"smolbox-record-v30", 0, _::binary>>} = Codec.encode(saved)
      assert {:ok, ^saved} = resolve(runtime, saved)
      refute_receive {:quiesce, _}
      refute_receive {:observe, _, _, _, _, _, _}
    end
  end

  for mode <- [
        :busy,
        :stale_epoch,
        :missing,
        :bare,
        :stream,
        :wrong_proof,
        :missing_source,
        :missing_child,
        :changed_source,
        :stopped_child,
        :late,
        :store_failure,
        :stale_commit
      ] do
    test "#{mode} cannot clear original creation uncertainty source exclusion or reservations" do
      {runtime, store, parent, child, _, usage, authority, worker} = fixture(unquote(mode))
      assert {:error, _} = resolve(runtime, child)
      assert fetch(store, child).branch.state == :unknown
      assert fetch(store, child).branch.native_authority.completion == nil
      assert fetch(store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      assert Process.alive?(worker.connection.context.server)
      if unquote(mode) in [:busy, :stale_epoch], do: refute_receive({:observe, _, _, _, _, _, _})

      if unquote(mode) in [:store_failure, :stale_commit],
        do: assert_receive({:store_resolution, true})
    end
  end

  test "an unknown reply retries the same frozen creation and draining permits original-result recovery" do
    {runtime, store, parent, child, _, usage, _, _} = fixture(:lost_once)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = resolve(runtime, child)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert_receive {:observe, true, true, _, _, first, _}
    assert {:ok, _} = resolve(runtime, fetch(store, child))
    assert_receive {:observe, true, true, _, _, second, _}
    assert first == second
  end

  for mode <- [:source_admission, :child_admission] do
    test "#{mode} after original completion retains uncertain records charges and the recovery fence" do
      {runtime, store, parent, child, _, usage, authority, worker} =
        fixture(unquote(mode), true, ready: true)

      assert NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)

      assert {:error,
              %Error{
                category: :admission_exhausted,
                operation: :branch,
                evidence: :dispatch_uncertain
              }} = resolve(runtime, child)

      assert fetch(store, child) == child
      # The original source claim renews before recovery; its content stays intact.
      claim_fields = [
        :version,
        :updated_at_ms,
        :claim_owner,
        :claim_until_ms,
        :generation,
        :worker_generation
      ]

      assert Map.drop(fetch(store, parent), claim_fields) == Map.drop(parent, claim_fields)
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      refute NativeAuthority.available?(SmolBox.Runtime.coordinator(runtime), worker.id)
      refute_receive {:store_resolution, _}
      refute_receive :activated_original_owner

      assert_receive {:observe, true, true, _, _,
                      %{"operation" => "resolve_ready_branch_completion"}, _}

      assert_receive {:observe, true, true, _, _, %{"operation" => "branch_preflight"}, _}

      if unquote(mode == :child_admission),
        do: assert_receive({:observe, true, true, _, _, %{"operation" => "inspect"}, _})

      refute_receive {:observe, _, _, _, _, _, _}
    end
  end

  test "draining keeps explicit result recovery available" do
    {runtime, _, _, child, _, _, _, _} = fixture(:draining)
    assert {:ok, _} = resolve(runtime, child)
  end

  test "the backend requires the exact fenced source scope and finite cumulative budgets" do
    {_, _, parent, child, result, _, _, worker} = fixture()
    {:ok, context} = Adapter.assign(worker.connection.context, parent)
    context = %{context | quiesced: true}
    budget = worker.connection.budget
    reject = fn _, _, _ -> flunk("unfenced or wrong source dispatched") end

    for wrong <- [
          %{context | pinned: false},
          %{context | quiesced: false},
          %{context | name: child.machine_name},
          %{context | assignment: child.backend_assignment},
          %{context | identity: nil}
        ] do
      assert {:error, _} =
               EmbeddedBranch.coordinate(
                 wrong,
                 :branch_resolve_creation,
                 parent,
                 child,
                 budget,
                 reject
               )
    end

    assert {:error, _} =
             EmbeddedBranch.coordinate(
               context,
               :branch_resolve_creation,
               parent,
               child,
               %{budget | max_request_bytes: 1},
               reject
             )

    assert {:error, _} =
             EmbeddedBranch.coordinate(
               context,
               :branch_resolve_creation,
               parent,
               child,
               budget,
               reject,
               System.monotonic_time(:millisecond) - 1
             )

    tiny = %{budget | max_response_bytes: 1}

    assert {:error, _} =
             EmbeddedBranch.coordinate(
               context,
               :branch_resolve_creation,
               parent,
               child,
               tiny,
               fn _, _, _ ->
                 {:ok,
                  %{
                    "result" => "branch_completion_presence",
                    "completion" => BranchCompletion.to_wire(result.completion)
                  }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
               end
             )

    assert Embedded.supports_operation?(nil, :resolve_ready_branch)
    refute Embedded.supports_operation?(context, :resolve_ready_branch)
    refute HTTP.supports_operation?(nil, :resolve_ready_branch)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Embedded.invoke(context, :resolve_ready_branch, [parent, child], budget)

    assert Keyword.fetch!(Backend.operations(), :resolve_ready_branch) == 3
  end

  test "completed exchanges consume cumulative budgets before any further native observation" do
    {_, _, parent, child, result, _, _, worker} = fixture()
    {:ok, context} = Adapter.assign(worker.connection.context, parent)
    context = %{context | quiesced: true}
    budget = worker.connection.budget

    operation = %{
      "operation" => "resolve_ready_branch_completion",
      "request" => child.branch.native_authority.request,
      "quiesced" => true
    }

    source = %{
      "operation" => "branch_preflight",
      "receipt" => result.completion.publication["receipt"]
    }

    leaf = %{"operation" => "inspect", "receipt" => result.completion.child}

    input =
      Enum.sum(Enum.map([operation, source, leaf], &byte_size(Jason.encode!(&1)))) + 3 * 1024 - 1

    assert {:error, %Error{category: :output_limit, evidence: :dispatch_uncertain}} =
             Adapter.invoke(context, :resolve_ready_branch, [parent, child], %{
               budget
               | max_request_bytes: input
             })

    assert_receive {:observe, _, _, _, _, %{"operation" => "resolve_ready_branch_completion"}, _}
    assert_receive {:observe, _, _, _, _, %{"operation" => "branch_preflight"}, _}
    refute_receive {:observe, _, _, _, _, %{"operation" => "inspect"}, _}

    output =
      byte_size(
        Jason.encode!(%{
          "result" => "branch_completion_presence",
          "completion" => BranchCompletion.to_wire(result.completion)
        })
      )

    assert {:error, %Error{category: :output_limit, evidence: :dispatch_uncertain}} =
             Adapter.invoke(context, :resolve_ready_branch, [parent, child], %{
               budget
               | max_response_bytes: output
             })

    assert_receive {:observe, _, _, _, _, %{"operation" => "resolve_ready_branch_completion"}, _}
    refute_receive {:observe, _, _, _, _, %{"operation" => "branch_preflight"}, _}
  end
end
