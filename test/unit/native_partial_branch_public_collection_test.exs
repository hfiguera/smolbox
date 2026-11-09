defmodule SmolBox.NativePartialBranchPublicCollectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine}

  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedPartialBranchCollection, Reference}
  alias SmolBox.Embedded.{Config, NativeGrowth, PartialBranchCollection}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativePartialBranchCollectionContract}

  alias NativePartialBranchCollectionContract, as: Contract

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

    def machine({store, observer, authority, worker, mode}, :branch_advance, args) do
      caller = self()
      held = Agent.get(authority, &(&1 == {worker, caller}))
      change = Enum.at(args, 4)
      send(observer, {:store_write, elem(change, 0), held})

      reject =
        (elem(change, 0) == :accept_partial_collection and mode == :accept_failure) or
          (elem(change, 0) == :complete_partial_collection and mode == :store_failure)

      if held and not reject,
        do: Memory.machine(store, :branch_advance, args),
        else: {:error, %Error{category: :store, operation: :branch}}
    end

    def machine({store, _, _, _, _}, operation, args), do: Memory.machine(store, operation, args)
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, Map.put(state, :collected, nil)}

    def handle_call({:quiesce, epoch}, _, state) do
      result =
        if epoch == state.epoch,
          do: :ok,
          else: {:error, %Error{category: :identity_conflict, operation: :embedded}}

      send(state.observer, {:quiesce, result})
      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:call, context, request, budget, child}, _, state) do
      send(state.observer, {:native_call, state.frozen, context.quiesced, request, budget})

      if state.collected,
        do: true = state.collected.proof.request_sha256 == request["request"]["request_sha256"]

      result = state.collected || Contract.result(child)

      if state.mode == :stale_child do
        {:ok, _} =
          Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])
      end

      outcome = %{
        "result" => "partial_branch_collected",
        "proof" => PartialBranchCollection.to_wire(result.proof),
        "platform" => if(state.mode == :wrong_platform, do: "linux", else: "macos")
      }

      empty = %{stdout: <<>>, stderr: <<>>, file: <<>>}

      response = response(state.mode, state.collected == nil, outcome, empty)

      {:reply, response, %{state | collected: result}}
    end

    defp response(mode, first, outcome, empty) do
      case mode do
        :not_dispatched ->
          {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}, empty,
           nil}

        :lost_reply when first ->
          {:error,
           %Error{category: :unknown, evidence: :dispatch_uncertain, operation: :embedded}}

        :output ->
          {:ok, outcome, %{empty | stdout: "unexpected"}, nil}

        :cursor ->
          {:ok, outcome, empty, "unexpected"}

        _ ->
          {:ok, outcome, empty, nil}
      end
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :collect_partial_branch
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

    def invoke(context, :collect_partial_branch, [parent, child], budget),
      do:
        EmbeddedPartialBranchCollection.coordinate(context, parent, child, budget, fn ctx,
                                                                                      request,
                                                                                      b ->
          GenServer.call(ctx.server, {:call, ctx, request, b, child})
        end)
  end

  defp fixture(mode \\ :normal, hold \\ true, transfer \\ 262_144) do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, hold)
    epoch = get_in(completion.completion.publication, ~w(change child_origin intent epoch))
    authority = start_supervised!({Agent, fn -> nil end})

    peer =
      start_supervised!(
        {Peer, %{observer: self(), epoch: epoch, frozen: false, store: store, mode: mode}}
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
      budget: %Budget{timeout_ms: 5000, max_request_bytes: transfer, max_response_bytes: transfer}
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

  defp collect(runtime, child, version \\ nil),
    do:
      Branches.collect_partial(runtime, ManagedMachine.key(child), version || child.version,
        quiesced: true
      )

  defp calls(acc \\ []) do
    receive do
      {:native_call, _, _, _, _} = call -> calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for hold <- [true, false] do
    test "held=#{hold} collection is fenced durable and retains every reservation and unknown creation" do
      {runtime, store, parent, child, usage, authority, context} = fixture(:normal, unquote(hold))
      assert {:ok, collected} = collect(runtime, child)
      assert_receive {:quiesce, :ok}
      assert_receive {:store_write, :accept_partial_collection, true}
      assert_receive {:store_write, :complete_partial_collection, true}
      assert [{:native_call, true, true, request, budget}] = calls()
      saved = collected.branch.native_authority.partial_collection
      assert request == %{"operation" => "collect_partial_branch", "request" => saved.request}
      assert saved.proof != nil and saved.platform == "macos"

      assert budget.timeout_ms <= 5000 and budget.max_request_bytes <= 21 * 1024 and
               budget.max_response_bytes <= 6 * 1024

      assert collected.state == :unknown and collected.branch.state == :unknown

      assert collected.reservation == child.reservation and collected.created_machine == nil and
               collected.observed_machine == nil

      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert {:ok, <<"smolbox-record-v44", 0, _::binary>>} = Codec.encode(collected)
      assert {:ok, ^collected} = collect(runtime, child)
      assert {:ok, ^collected} = collect(runtime, collected)
      refute_receive {:quiesce, _}
      assert calls() == [] and Agent.get(authority, & &1) == nil
      assert Process.alive?(context.server)
    end
  end

  for mode <- [:accept_failure, :stale_epoch] do
    test "#{mode} rejects without accepting or dispatching collection" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, _} = collect(runtime, child)

      assert Contract.fetch(Memory, store, child).branch.native_authority.partial_collection ==
               nil

      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert calls() == [] and Agent.get(authority, & &1) == nil
    end
  end

  for mode <- [:stale_child, :store_failure, :wrong_platform, :output, :cursor] do
    test "#{mode} cannot acknowledge collection or release original capacity" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = collect(runtime, child)
      saved = Contract.fetch(Memory, store, child)
      assert saved.branch.native_authority.partial_collection.proof == nil
      assert saved.state == :unknown and saved.branch.state == :unknown
      assert saved.reservation == child.reservation
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
      assert [_] = calls()
    end
  end

  test "a lost reply retries exactly the frozen request against its retained original acknowledgement" do
    {runtime, store, parent, child, usage, _, _} = fixture(:lost_reply)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = collect(runtime, child)
    pending = Contract.fetch(Memory, store, child)
    assert pending.branch.native_authority.partial_collection.proof == nil
    assert [{:native_call, true, true, first, _}] = calls()
    assert {:ok, collected} = collect(runtime, child)
    assert [{:native_call, true, true, ^first, _}] = calls()
    assert collected.branch.native_authority.partial_collection.proof != nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "a definitive helper rejection retains not-dispatched evidence and the accepted request" do
    {runtime, store, parent, child, usage, _, _} = fixture(:not_dispatched)
    assert {:error, %Error{evidence: :not_dispatched}} = collect(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_collection.proof ==
             nil

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert [_] = calls()
  end

  test "retained collection is allowed while draining" do
    {runtime, _, _, child, _, _, _} = fixture(:draining)
    assert {:ok, _} = collect(runtime, child)
    assert [_] = calls()
  end

  test "invalid options and stale versions do not contact the helper" do
    {runtime, store, _, child, _, _, _} = fixture()

    assert {:error, _} =
             Branches.collect_partial(runtime, ManagedMachine.key(child), child.version, [])

    assert {:error, _} = collect(runtime, child, child.version + 100)
    assert Contract.fetch(Memory, store, child) == child
    assert calls() == []
    refute_receive {:quiesce, _}
  end

  test "an exhausted request allowance cannot dispatch collection" do
    {runtime, store, parent, child, usage, _, _} = fixture(:normal, true, 1024)

    assert {:error, %Error{category: :output_limit, evidence: :not_dispatched}} =
             collect(runtime, child)

    assert Contract.fetch(Memory, store, child).branch.native_authority.partial_collection.proof ==
             nil

    assert calls() == []
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "an already expired adapter deadline cannot call a peer" do
    {_, store, parent, child, _, _, context} = fixture()
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)
    budget = %Budget{timeout_ms: 5000, max_request_bytes: 21 * 1024, max_response_bytes: 6 * 1024}
    callback = fn _, _, _ -> flunk("expired collection dispatched") end

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             EmbeddedPartialBranchCollection.coordinate(
               context,
               parent,
               pending,
               budget,
               callback,
               System.monotonic_time(:millisecond) - 1
             )

    assert Contract.fetch(Memory, store, pending) == pending
  end

  test "an accepted platform cannot move to a different pinned target before dispatch" do
    {_, store, parent, child, _, _, context} = fixture()
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    {:ok, context} = Adapter.assign(%{context | quiesced: true}, parent)
    context = %{context | config: %{context.config | platform: :linux}}
    budget = %Budget{timeout_ms: 5000, max_request_bytes: 21 * 1024, max_response_bytes: 6 * 1024}

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             EmbeddedPartialBranchCollection.coordinate(context, parent, pending, budget, fn _,
                                                                                             _,
                                                                                             _ ->
               flunk("cross-platform collection dispatched")
             end)
  end
end
