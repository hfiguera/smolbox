defmodule SmolBox.NativeUnbootedBranchPublicBackingTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{
    Budget,
    EmbeddedBranchBacking,
    EmbeddedContext,
    Reference
  }

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    Config,
    NativeGrowth,
    UnbootedBranchDisposal
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativeUnbootedBranchBackingContract}

  alias NativeUnbootedBranchBackingContract, as: Contract

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

    def machine({store, observer, authority, worker, mode}, operation, args)
        when operation in [:branch_backing_accept, :branch_release_storage] do
      caller = self()
      held = Agent.get(authority, &(&1 == {worker, caller}))
      send(observer, {:store_backing, operation, held})

      fail =
        (mode == :store_failure and operation == :branch_release_storage) or
          (mode == :accept_failure and operation == :branch_backing_accept)

      if held and not fail,
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

      proof = Contract.proof(operation["request"])
      send(state.observer, {:native_ack, proof})
      wire = BranchBackingRelease.to_wire(proof)

      reply =
        case state.mode do
          :missing ->
            {:ok, %{"result" => "error", "code" => "ownership", "dispatch" => "not_dispatched"},
             empty(), nil}

          :bare ->
            {:ok, :absent}

          :stream ->
            {:ok, %{"result" => "branch_backing_released", "proof" => wire},
             %{empty() | stdout: "extra"}, nil}

          :wrong_proof ->
            {:ok,
             %{
               "result" => "branch_backing_released",
               "proof" => %{wire | "native_bytes" => wire["native_bytes"] + 1}
             }, empty(), nil}

          :lost_once ->
            {:error,
             %Error{category: :unknown, operation: :branch, evidence: :dispatch_uncertain}}

          _ ->
            {:ok, %{"result" => "branch_backing_released", "proof" => wire}, empty(), nil}
        end

      state = if state.mode == :lost_once, do: %{state | mode: :normal}, else: state
      {:reply, reply, state}
    end

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :release_branch_backing
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

    def invoke(context, :release_branch_backing, [parent, child, removed], budget),
      do: EmbeddedBranchBacking.coordinate(context, parent, child, removed, budget, &call/3)

    defp call(context, operation, budget),
      do: GenServer.call(context.server, {:observe, context, operation, budget})
  end

  defp fixture(mode \\ :normal, hold \\ true, provenance \\ "deleted") do
    store = start_supervised!(Memory)
    {parent, child, usage} = Contract.prepare(Memory, store, hold, provenance)

    epoch =
      get_in(
        UnbootedBranchDisposal.to_wire(child.branch.native_authority.disposal.proof),
        ~w(publication change child_origin intent epoch)
      )

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
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}
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

    {runtime, store, parent, child, usage, authority, worker}
  end

  defp release(runtime, child),
    do: Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: true)

  for hold <- [true, false], provenance <- ["deleted", "resolved_absent"] do
    test "held=#{hold} provenance=#{provenance} closes original unbooted backing under the same fence" do
      {runtime, store, parent, child, _, authority, worker} =
        fixture(:normal, unquote(hold), unquote(provenance))

      assert {:ok, closed} = release(runtime, child)
      assert closed.branch.state == :closed and closed.created_machine == nil
      assert closed.branch.native_authority.completion == nil
      assert closed.branch.native_authority.disposal == child.branch.native_authority.disposal
      assert closed.branch.native_authority.retirement == child.branch.native_authority.retirement

      assert {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
               Memory.usage(store, parent.worker_id)

      assert_receive {:quiesce, :ok}
      assert_receive {:store_backing, :branch_backing_accept, true}

      assert_receive {:observe, true, true, peer, epoch,
                      %{"operation" => "release_unbooted_branch_backing", "request" => request},
                      budget}

      assert peer == worker.connection.context.server and epoch == worker.connection.context.epoch
      assert request == closed.branch.native_authority.backing.request

      assert budget.timeout_ms <= 1000 and budget.max_request_bytes <= 84 * 1024 and
               budget.max_response_bytes <= 72 * 1024

      assert_receive {:native_ack, proof}
      assert proof == closed.branch.native_authority.backing.proof
      assert_receive {:store_backing, :branch_release_storage, true}
      assert Agent.get(authority, & &1) == nil
      assert {:ok, <<"smolbox-record-v39", 0, _::binary>>} = Codec.encode(closed)
      assert {:ok, ^closed} = release(runtime, closed)
      assert {:ok, ^closed} = Branches.retire(runtime, ManagedMachine.key(closed), quiesced: true)
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
        :store_failure,
        :accept_failure
      ] do
    test "#{mode} preserves the original disposal retirement and full backing charge" do
      {runtime, store, parent, child, usage, authority, worker} = fixture(unquote(mode))
      assert {:error, _} = release(runtime, child)
      current = Contract.fetch(Memory, store, child)
      assert current.branch.native_authority.disposal == child.branch.native_authority.disposal

      assert current.branch.native_authority.retirement ==
               child.branch.native_authority.retirement

      assert current.branch.native_authority.completion == nil
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

      if unquote(mode) in [:busy, :stale_epoch, :accept_failure] do
        assert current.branch.native_authority.backing == nil
        refute_receive {:observe, _, _, _, _, _, _}
      else
        assert current.branch.state == :backing_pending
        assert current.branch.native_authority.backing.proof == nil
      end

      assert Agent.get(authority, & &1) == nil
      assert Process.alive?(worker.connection.context.server)
    end
  end

  test "a lost acknowledgement keeps the accepted request and only its exact retry closes accounting" do
    {runtime, store, parent, child, usage, _, _} = fixture(:lost_once)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = release(runtime, child)
    pending = Contract.fetch(Memory, store, child)
    assert pending.branch.state == :backing_pending
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    saved = pending.branch.native_authority.backing
    assert_receive {:native_ack, first}
    assert {:ok, closed} = release(runtime, pending)
    assert_receive {:native_ack, second}
    assert first == second
    assert closed.branch.native_authority.backing == %{saved | proof: first}
    assert {:ok, %{disk_gb: 0}} = Memory.usage(store, parent.worker_id)
  end

  test "draining permits retained cleanup and explicit host confirmation is mandatory" do
    {runtime, _, _, child, _, _, _} = fixture(:draining)

    assert {:error, %Error{category: :validation}} =
             Branches.release_storage(runtime, ManagedMachine.key(child), backing_removed: false)

    refute_receive {:quiesce, _}
    assert {:ok, %{branch: %{state: :closed}}} = release(runtime, child)
  end

  test "wrong source scope original epoch platform request and response budgets cannot close backing" do
    {_, store, parent, child, usage, _, worker} = fixture()
    assert {:ok, child} = Contract.accept(Memory, store, parent, child, 1312)
    parent = Contract.fetch(Memory, store, parent)
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
          %{context | assignment: child.backend_assignment},
          %{context | identity: nil}
        ] do
      assert {:error, _} =
               EmbeddedBranchBacking.coordinate(wrong, parent, child, true, budget, reject)
    end

    assert {:error, _} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               %{budget | max_request_bytes: 1},
               reject
             )

    assert {:error, %Error{category: :expired}} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               budget,
               reject,
               System.monotonic_time(:millisecond) - 1
             )

    for wrong_parent <- [
          %{parent | state: :running},
          %{parent | native_branch_history: %{}},
          %{parent | branch_children: %{child.id => false}},
          %{parent | branch_children: %{child.id => true, "other-child" => false}}
        ] do
      assert {:error, _} =
               EmbeddedBranchBacking.coordinate(
                 context,
                 wrong_parent,
                 child,
                 true,
                 budget,
                 reject
               )
    end

    assert {:error, _} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               put_in(child.branch.native_authority.backing, nil),
               true,
               budget,
               reject
             )

    assert {:error, _} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               put_in(child.branch.native_authority.retirement, nil),
               true,
               budget,
               reject
             )

    proof = Contract.proof(child.branch.native_authority.backing.request)

    response =
      {:ok,
       %{"result" => "branch_backing_released", "proof" => BranchBackingRelease.to_wire(proof)},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

    assert {:error, _} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               %{budget | max_response_bytes: 1},
               fn _, _, _ -> response end
             )

    late = fn _, _, _ ->
      Process.sleep(80)
      response
    end

    assert {:error, %Error{category: :expired}} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               budget,
               late,
               System.monotonic_time(:millisecond) + 50
             )

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end
end
