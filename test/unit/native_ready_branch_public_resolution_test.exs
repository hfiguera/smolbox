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

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
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

  defp fixture(mode \\ :normal, hold \\ true) do
    store = start_supervised!(Memory)
    {parent, child, result} = Contract.prepare(Memory, store, hold)

    assert {:ok, _} =
             Contract.advance(Memory, store, parent, child, :accepted, :dispatching, 1101)

    parent = fetch(store, parent)

    assert {:ok, child} =
             Contract.advance(Memory, store, parent, child, :dispatching, :unknown, 1102)

    parent = fetch(store, parent)
    {:ok, usage} = Memory.usage(store, parent.worker_id)
    epoch = get_in(result.completion.publication, ~w(change child_origin intent epoch))
    authority = start_supervised!({Agent, fn -> nil end})

    peer =
      start_supervised!(
        {Peer, %{observer: self(), epoch: epoch, frozen: false, mode: mode, result: result}}
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
        timeout_ms: if(mode == :late, do: 50, else: 1000),
        max_request_bytes: 131_072,
        max_response_bytes: 131_072
      }
    }

    worker = %Target{
      kind: :embedded,
      id: parent.worker_id,
      connection: reference,
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

    {runtime, store, parent, child, result, usage, authority, worker}
  end

  defp fetch(store, record) do
    {:ok, current} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])
    current
  end

  defp resolve(runtime, child),
    do: Branches.resolve(runtime, ManagedMachine.key(child), quiesced: true, disposition: :keep)

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
