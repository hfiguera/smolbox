defmodule SmolBox.NativePreparedBranchPublicRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{
    Budget,
    EmbeddedContext,
    EmbeddedPreparedBranchRetirement,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{
    Config,
    NativeGrowth,
    NativePreparedBranchRetirement,
    PreparedBranchRetirement
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativePreparedBranchRetirementContract}

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

    def machine({store, observer, authority, worker, fail}, operation, args) do
      if operation == :branch_resolve do
        caller = self()
        held = Agent.get(authority, &(&1 == {worker, caller}))
        send(observer, {:store_resolution, held})

        if held and not fail,
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
    def init(state), do: {:ok, state}

    def handle_call({:quiesce, epoch}, _, state) do
      result =
        if state.mode == :busy or epoch != state.epoch,
          do: {:error, %Error{category: :identity_conflict, operation: :embedded}},
          else: :ok

      send(state.observer, {:quiesce, result})
      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:retire, context, operation, budget}, _, state) do
      send(
        state.observer,
        {:retire, state.frozen, context.quiesced, context.epoch, operation, budget}
      )

      if state.mode == :stale_child do
        {:ok, _} =
          Memory.machine(state.store, :claim, [
            ManagedMachine.key(state.child),
            "owner",
            1400,
            10_000
          ])
      end

      proof = PreparedBranchRetirement.to_wire(state.result.proof)

      proof =
        if state.mode == :wrong_proof,
          do: %{proof | "request_sha256" => String.duplicate("0", 64)},
          else: proof

      response =
        case state.mode do
          :bare ->
            {:ok, :absent}

          :entered ->
            {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"},
             empty(), nil}

          :stream ->
            {:ok, %{"result" => "prepared_branch_retired", "proof" => proof},
             %{empty() | stdout: "extra"}, nil}

          _ ->
            {:ok, %{"result" => "prepared_branch_retired", "proof" => proof}, empty(), nil}
        end

      {:reply, response, state}
    end

    def handle_call({:inspect, context, operation, budget}, _, state) do
      send(state.observer, {:inspect, context.server, context.epoch, operation, budget})
      resources = EmbeddedContext.resources(context)

      resources =
        if state.mode == :changed_source,
          do: Map.update!(resources, "cpus", &(&1 + 1)),
          else: resources

      response =
        if state.mode == :missing_source,
          do:
            {:error, %Error{category: :not_found, operation: :inspect, evidence: :not_dispatched}},
          else:
            {:ok,
             %{
               "result" => "observed",
               "observation" => %{
                 "resources" => resources,
                 "state" => if(state.mode == :stopped, do: "stopped", else: "running"),
                 "pid_identity" =>
                   if(state.mode == :stopped,
                     do: nil,
                     else: state.result.source.backend_identity.pid_identity
                   )
               }
             }, empty(), nil}

      {:reply, response, state}
    end

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :retire_prepared_branch
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

    def invoke(context, :retire_prepared_branch, [parent, child], budget),
      do: EmbeddedPreparedBranchRetirement.coordinate(context, parent, child, budget, &call/3)

    defp call(context, %{"operation" => "retire_prepared_branch"} = operation, budget),
      do: GenServer.call(context.server, {:retire, context, operation, budget})

    defp call(context, %{"operation" => "inspect"} = operation, budget),
      do: GenServer.call(context.server, {:inspect, context, operation, budget})
  end

  defmodule BareAdapter do
    @behaviour SmolBox.Backend
    defdelegate supports_operation?(context, operation), to: Adapter
    defdelegate pin(context, budget), to: Adapter
    defdelegate assign(context, record), to: Adapter
    def invoke(_, :retire_prepared_branch, _, _), do: {:ok, :absent}
  end

  defp fixture(mode \\ :normal, hold \\ true) do
    store = start_supervised!(Memory)

    {parent, child, result, usage} =
      NativePreparedBranchRetirementContract.prepare(Memory, store, hold)

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
           mode: mode,
           result: result
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: peer,
      pinned: true,
      epoch: if(mode == :stale_epoch, do: String.duplicate("b", 32), else: epoch)
    }

    reference = %Reference{
      adapter: if(mode == :adapter_bare, do: BareAdapter, else: Adapter),
      kind: :embedded,
      id: parent.worker_id,
      context: context,
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}
    }

    target = %Target{kind: :embedded, id: parent.worker_id, connection: reference}

    config = %{
      managed_machines: true,
      store: {Store, {store, self(), authority, parent.worker_id, mode == :store_failure}},
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

    {runtime, store, parent, child, usage, authority, context, result}
  end

  for hold <- [true, false] do
    test "held=#{hold} public deleted resolution fences original proof and unchanged source through atomic commit" do
      {runtime, store, parent, child, _usage, authority, context, result} =
        fixture(:normal, unquote(hold))

      assert {:ok, retired} =
               Branches.resolve(runtime, ManagedMachine.key(child),
                 quiesced: true,
                 disposition: :deleted
               )

      assert retired.state == :deleted and retired.branch.state == :closed
      assert retired.created_machine == nil and retired.observed_machine == nil
      assert retired.branch.native_authority.prepared_retirement.proof == result.proof
      assert_receive {:quiesce, :ok}
      assert_receive {:retire, true, true, epoch, operation, transfer_budget}
      assert_receive {:inspect, peer, ^epoch, %{"operation" => "inspect"}, observation_budget}
      assert peer == context.server and epoch == context.epoch
      assert operation["request"]["creation"] == child.branch.native_authority.request
      assert observation_budget.timeout_ms <= transfer_budget.timeout_ms
      assert observation_budget.max_request_bytes < transfer_budget.max_request_bytes
      assert observation_budget.max_response_bytes < transfer_budget.max_response_bytes
      assert_receive {:store_resolution, true}
      assert Agent.get(authority, & &1) == nil
      assert {:ok, source} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])

      assert source.native_branch_history[child.id] ==
               retired.branch.native_authority.prepared_retirement

      assert source.observed_machine == result.source
      assert {:ok, <<"smolbox-record-v36\0", _::binary>>} = Codec.encode(retired)

      assert {:ok, ^retired} =
               Branches.resolve(runtime, ManagedMachine.key(child),
                 quiesced: true,
                 disposition: :deleted
               )

      refute_receive {:quiesce, _}
      refute_receive {:retire, _, _, _, _, _}
    end
  end

  for mode <- [
        :adapter_bare,
        :busy,
        :stale_epoch,
        :bare,
        :stream,
        :wrong_proof,
        :entered,
        :missing_source,
        :changed_source,
        :stale_child,
        :store_failure
      ] do
    test "#{mode} cannot release source exclusion or reservations" do
      {runtime, store, parent, child, usage, authority, _, _} = fixture(unquote(mode))

      assert {:error, error} =
               Branches.resolve(runtime, ManagedMachine.key(child),
                 quiesced: true,
                 disposition: :deleted
               )

      if unquote(mode) in [
           :adapter_bare,
           :missing_source,
           :changed_source,
           :stale_child,
           :store_failure
         ],
         do: assert(error.evidence == :dispatch_uncertain)

      if unquote(mode) == :entered, do: assert(error.evidence == :not_dispatched)
      assert {:ok, source} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert source.active_branch == child.id and source.branch_children[child.id] == false
      assert source.native_branch_history == %{}
      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
      assert saved.branch.native_authority.prepared_retirement == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
    end
  end

  test "a positively stopped source remains stopped after prepared-only resolution" do
    {runtime, store, parent, child, _, _, _, _} = fixture(:stopped)

    assert {:ok, retired} =
             Branches.resolve(runtime, ManagedMachine.key(child),
               quiesced: true,
               disposition: :deleted
             )

    assert retired.branch.state == :closed

    assert {:ok, %{state: :stopped} = source} =
             Memory.machine(store, :fetch, [ManagedMachine.key(parent)])

    assert source.observed_machine.backend_identity.pid_identity == nil
  end

  test "quiescence must be explicit before public dispatch" do
    {runtime, _, _, child, _, _, _, _} = fixture()

    assert {:error, %{category: :validation}} =
             Branches.resolve(runtime, ManagedMachine.key(child), disposition: :deleted)

    refute_receive {:quiesce, _}
    refute_receive {:retire, _, _, _, _, _}
  end

  for side <- [:input, :output] do
    test "#{side} payload budget covers retirement plus observation together" do
      {_, _, parent, child, _, _, context, result} = fixture()
      {:ok, context} = Adapter.assign(context, parent)
      context = %{context | quiesced: true}

      operation = %{
        "operation" => "retire_prepared_branch",
        "request" => NativePreparedBranchRetirement.request(child.branch.native_authority)
      }

      inspect_request = %{"operation" => "inspect", "receipt" => context.identity.receipt}

      proof = %{
        "result" => "prepared_branch_retired",
        "proof" => PreparedBranchRetirement.to_wire(result.proof)
      }

      observed = %{
        "result" => "observed",
        "observation" => %{
          "state" => "running",
          "resources" => EmbeddedContext.resources(context),
          "pid_identity" => [123, 456]
        }
      }

      total_input =
        byte_size(Jason.encode!(operation)) + byte_size(Jason.encode!(inspect_request))

      total_output = byte_size(Jason.encode!(proof)) + byte_size(Jason.encode!(observed))

      budget = %Budget{
        timeout_ms: 1000,
        max_request_bytes: total_input,
        max_response_bytes: total_output
      }

      budget =
        if unquote(side) == :input,
          do: %{budget | max_request_bytes: total_input - 1},
          else: %{budget | max_response_bytes: total_output - 1}

      call = fn _, request, _ ->
        send(self(), {:bounded_call, request["operation"]})

        {:ok, if(request["operation"] == "inspect", do: observed, else: proof),
         %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
      end

      assert {:error, %{evidence: :dispatch_uncertain}} =
               EmbeddedPreparedBranchRetirement.coordinate(context, parent, child, budget, call)

      assert_receive {:bounded_call, "retire_prepared_branch"}

      if unquote(side) == :input,
        do: refute_receive({:bounded_call, "inspect"}),
        else: assert_receive({:bounded_call, "inspect"})

      assert {:ok, _} =
               EmbeddedPreparedBranchRetirement.coordinate(
                 context,
                 parent,
                 child,
                 %{budget | max_request_bytes: total_input, max_response_bytes: total_output},
                 call
               )
    end
  end

  test "one finite deadline rejects a late proof before any source observation" do
    {_, _, parent, child, _, _, context, result} = fixture()
    {:ok, context} = Adapter.assign(context, parent)
    context = %{context | quiesced: true}

    call = fn _, request, _ ->
      send(self(), {:deadline_call, request["operation"]})
      Process.sleep(80)

      {:ok,
       %{
         "result" => "prepared_branch_retired",
         "proof" => PreparedBranchRetirement.to_wire(result.proof)
       }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    assert {:error, %{category: :expired, evidence: :dispatch_uncertain}} =
             EmbeddedPreparedBranchRetirement.coordinate(
               context,
               parent,
               child,
               %Budget{timeout_ms: 50, max_request_bytes: 131_072, max_response_bytes: 131_072},
               call
             )

    assert_receive {:deadline_call, "retire_prepared_branch"}
    refute_receive {:deadline_call, "inspect"}
  end

  test "native-only operation does not dispatch through HTTP or unqualified production policy" do
    {_, _, parent, child, _, _, context, _} = fixture()
    refute HTTP.supports_operation?(nil, :retire_prepared_branch)

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedPreparedBranchRetirement.run(context, parent, child, %Budget{
               timeout_ms: 1000,
               max_request_bytes: 131_072,
               max_response_bytes: 131_072
             })

    refute_receive {:retire, _, _, _, _, _}
    assert Keyword.fetch!(Backend.operations(), :retire_prepared_branch) == 3
  end
end
