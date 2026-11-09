defmodule SmolBox.NativeUnbootedBranchPublicRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedContext,
    EmbeddedUnbootedBranchRetirement,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{
    Config,
    NativeBranchRetirement,
    NativeGrowth,
    UnbootedBranchChildAbsence
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativeUnbootedBranchRetirementContract}

  alias NativeUnbootedBranchRetirementContract, as: Contract

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

    def machine({store, observer, authority, worker, mode}, :branch_retire = operation, args) do
      caller = self()
      held = Agent.get(authority, &(&1 == {worker, caller}))
      send(observer, {:store_retirement, held})

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
      reply =
        if state.mode != :busy and epoch == state.epoch,
          do: :ok,
          else: {:error, %Error{category: :identity_conflict, operation: :embedded}}

      send(state.observer, {:quiesce, reply})
      {:reply, reply, %{state | frozen: reply == :ok}}
    end

    def handle_call({:observe, context, operation, budget}, _, state) do
      send(
        state.observer,
        {:observe, state.frozen, context.quiesced, context.server, context.epoch, operation,
         budget}
      )

      if state.mode == :stale_child,
        do:
          Memory.machine(state.store, :claim, [
            ManagedMachine.key(state.child),
            "owner",
            1400,
            10_000
          ])

      proof = UnbootedBranchChildAbsence.to_wire(state.proof)

      reply =
        case state.mode do
          :missing ->
            {:ok, %{"result" => "error", "code" => "ownership", "dispatch" => "not_dispatched"},
             empty(), nil}

          :bare ->
            {:ok, :absent}

          :stream ->
            {:ok, %{"result" => "unbooted_branch_child_absent", "proof" => proof},
             %{empty() | stdout: "extra"}, nil}

          :wrong_proof ->
            {:ok,
             %{
               "result" => "unbooted_branch_child_absent",
               "proof" => %{proof | "proof_sha256" => String.duplicate("0", 64)}
             }, empty(), nil}

          _ ->
            {:ok, %{"result" => "unbooted_branch_child_absent", "proof" => proof}, empty(), nil}
        end

      {:reply, reply, state}
    end

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :retire_unbooted_branch
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

    def invoke(context, :retire_unbooted_branch, [parent, child], budget),
      do: EmbeddedUnbootedBranchRetirement.coordinate(context, parent, child, budget, &call/3)

    defp call(context, operation, budget),
      do: GenServer.call(context.server, {:observe, context, operation, budget})
  end

  defp fixture(mode \\ :normal, hold \\ true) do
    store = start_supervised!(Memory)
    {parent, child, proof, usage} = Contract.prepare(Memory, store, hold)
    epoch = UnbootedBranchChildAbsence.epoch(proof.request)
    authority = start_supervised!({Agent, fn -> nil end})

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           epoch: epoch,
           frozen: false,
           mode: mode,
           store: store,
           child: child,
           proof: proof
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
      budget: %Budget{timeout_ms: 5000, max_request_bytes: 131_072, max_response_bytes: 131_072}
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

    {runtime, store, parent, child, proof, usage, authority, worker}
  end

  defp retire(runtime, child),
    do: Branches.retire(runtime, ManagedMachine.key(child), quiesced: true)

  for hold <- [true, false] do
    test "held=#{hold} public retirement binds original absence and keeps the controller fence through the paired commit" do
      {runtime, store, parent, child, proof, usage, authority, worker} =
        fixture(:normal, unquote(hold))

      assert {:ok, retired} = retire(runtime, child)
      assert retired.branch.state == :retired and retired.created_machine == nil
      assert retired.branch.native_authority.disposal == child.branch.native_authority.disposal
      assert retired.branch.native_authority.retirement.proof == proof
      assert Contract.fetch(Memory, store, parent).branch_children[child.id] == true
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert_receive {:quiesce, :ok}

      assert_receive {:observe, true, true, peer, epoch,
                      %{
                        "operation" => "qualify_unbooted_branch_child_absence",
                        "request" => request
                      }, budget}

      assert peer == worker.connection.context.server and epoch == worker.connection.context.epoch
      assert request == proof.request

      assert budget.timeout_ms <= 5000 and budget.max_request_bytes <= 72 * 1024 and
               budget.max_response_bytes <= 72 * 1024

      assert_receive {:store_retirement, true}
      assert Agent.get(authority, & &1) == nil
      assert {:ok, <<"smolbox-record-v38", 0, _::binary>>} = Codec.encode(retired)
      assert {:ok, ^retired} = retire(runtime, retired)
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
        :stale_child,
        :store_failure
      ] do
    test "#{mode} cannot retire the dependency or free backing" do
      {runtime, store, parent, child, _, usage, authority, worker} = fixture(unquote(mode))
      assert {:error, _} = retire(runtime, child)
      assert Contract.fetch(Memory, store, parent).branch_children[child.id] == false
      assert Contract.fetch(Memory, store, child).branch.native_authority.retirement == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      assert Process.alive?(worker.connection.context.server)
      if unquote(mode) in [:busy, :stale_epoch], do: refute_receive({:observe, _, _, _, _, _, _})
      if unquote(mode) == :store_failure, do: assert_receive({:store_retirement, true})
    end
  end

  test "draining keeps retained original-child retirement available" do
    {runtime, _, _, child, _, _, _, _} = fixture(:draining)
    assert {:ok, %{branch: %{state: :retired}}} = retire(runtime, child)
  end

  test "backend refuses mismatched source pins epochs scopes and exhausted budgets before IO" do
    {_, _, parent, child, proof, _, _, worker} = fixture()
    {:ok, context} = Adapter.assign(worker.connection.context, parent)
    context = %{context | quiesced: true}
    budget = worker.connection.budget
    reject = fn _, _, _ -> flunk("invalid source scope dispatched") end

    for wrong <- [
          %{context | pinned: false},
          %{context | quiesced: false},
          %{context | epoch: String.duplicate("0", 32)},
          put_in(context.config.platform, :linux),
          %{context | name: child.machine_name},
          %{context | assignment: child.backend_assignment}
        ] do
      assert {:error, _} =
               EmbeddedUnbootedBranchRetirement.coordinate(wrong, parent, child, budget, reject)
    end

    assert {:error, _} =
             EmbeddedUnbootedBranchRetirement.coordinate(
               context,
               parent,
               child,
               %{budget | max_request_bytes: 1},
               reject
             )

    assert {:error, _} =
             EmbeddedUnbootedBranchRetirement.coordinate(
               context,
               parent,
               child,
               budget,
               reject,
               System.monotonic_time(:millisecond) - 1
             )

    response =
      {:ok,
       %{
         "result" => "unbooted_branch_child_absent",
         "proof" => UnbootedBranchChildAbsence.to_wire(proof)
       }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

    assert {:error, _} =
             EmbeddedUnbootedBranchRetirement.coordinate(
               context,
               parent,
               child,
               %{budget | max_response_bytes: 1},
               fn _, _, _ -> response end
             )

    assert {:ok, request} = NativeBranchRetirement.request(child)
    assert request == proof.request
    assert Embedded.supports_operation?(nil, :retire_unbooted_branch)
    refute Embedded.supports_operation?(context, :retire_unbooted_branch)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Embedded.invoke(context, :retire_unbooted_branch, [parent, child], budget)

    refute HTTP.supports_operation?(nil, :retire_unbooted_branch)
    assert Keyword.fetch!(Backend.operations(), :retire_unbooted_branch) == 3
  end
end
