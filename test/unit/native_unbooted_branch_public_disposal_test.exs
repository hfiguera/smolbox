defmodule SmolBox.NativeUnbootedBranchPublicDisposalTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Branches, Error, ManagedMachine, Profile}

  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedUnbootedBranchDisposal, Reference}

  alias SmolBox.Embedded.{
    Config,
    NativeGrowth,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Codec, Memory, NativeUnbootedBranchDisposalContract}

  alias NativeUnbootedBranchDisposalContract, as: Contract

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
    def init(state), do: {:ok, Map.put(state, :disposed, nil)}

    def handle_call({:quiesce, epoch}, _, state) do
      result =
        if epoch == state.epoch,
          do: :ok,
          else: {:error, %Error{category: :identity_conflict, operation: :embedded}}

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

    defp respond(_, %{"operation" => "retire_prepared_branch"}, _, state), do: {failure(), state}

    defp respond(_, %{"operation" => "inspect_unbooted_branch_disposal"}, child, state) do
      wire = UnbootedBranchDisposalCandidate.to_wire(state.candidate)

      wire =
        if state.mode == :invalid_candidate,
          do: %{wire | "proof_sha256" => String.duplicate("0", 64)},
          else: wire

      if state.mode == :stale_before_accept,
        do:
          Memory.machine(state.store, :claim, [
            ManagedMachine.key(child),
            "owner",
            1400,
            10_000
          ])

      response =
        if state.mode == :missing_candidate,
          do: failure(),
          else:
            {:ok, %{"result" => "unbooted_branch_disposal_candidate", "candidate" => wire},
             empty(), nil}

      {response, state}
    end

    defp respond(
           _,
           %{"operation" => "resolve_unbooted_branch_disposal"},
           _,
           %{disposed: nil} = state
         ),
         do: {failure(), state}

    defp respond(_, %{"operation" => "resolve_unbooted_branch_disposal"}, _, state),
      do: {proof(state.disposed), state}

    defp respond(_, %{"operation" => "dispose_unbooted_branch"}, child, state) do
      result = Contract.result(child, state.completion)

      if state.mode == :stale_child,
        do:
          Memory.machine(state.store, :claim, [ManagedMachine.key(child), "owner", 1400, 10_000])

      response =
        if state.mode == :lost_disposal and state.disposed == nil,
          do:
            {:error,
             %Error{category: :unknown, operation: :embedded, evidence: :dispatch_uncertain}},
          else: proof(result)

      {response, %{state | disposed: result}}
    end

    defp respond(context, %{"operation" => "inspect"}, _, state) do
      pid = state.completion.source.backend_identity.pid_identity
      pid = if state.mode == :wrong_source, do: [999, 999], else: pid

      {{:ok,
        %{
          "result" => "observed",
          "observation" => %{
            "resources" => EmbeddedContext.resources(context),
            "state" => "running",
            "pid_identity" => pid
          }
        }, empty(), nil}, state}
    end

    defp proof(result),
      do:
        {:ok,
         %{
           "result" => "unbooted_branch_disposed",
           "proof" => UnbootedBranchDisposal.to_wire(result.proof)
         }, empty(), nil}

    defp failure,
      do:
        {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}, empty(),
         nil}

    defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation),
      do:
        operation in [
          :retire_prepared_branch,
          :inspect_unbooted_branch_disposal,
          :dispose_unbooted_branch,
          :resolve_unbooted_branch_disposal
        ]

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

    def invoke(context, :retire_prepared_branch, [_, child], budget),
      do: call(context, %{"operation" => "retire_prepared_branch"}, budget, child)

    def invoke(context, operation, [parent, child], budget),
      do:
        EmbeddedUnbootedBranchDisposal.coordinate(
          context,
          operation,
          parent,
          child,
          budget,
          fn ctx, request, b -> call(ctx, request, b, child) end
        )

    defp call(context, request, budget, child),
      do: GenServer.call(context.server, {:call, context, request, budget, child})
  end

  defp fixture(mode \\ :normal, hold \\ true, timeout \\ 1000, transfer \\ 262_144) do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, hold)

    candidate = %{
      "schema" => 1,
      "creation" => child.branch.native_authority.request,
      "publication" => completion.completion.publication,
      "preparation_sha256" => String.duplicate("f", 64)
    }

    candidate =
      Map.put(candidate, "proof_sha256", UnbootedBranchDisposalCandidate.proof_digest(candidate))

    {:ok, candidate} = UnbootedBranchDisposalCandidate.from_wire(candidate)
    epoch = get_in(candidate.publication, ~w(change child_origin intent epoch))
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
           candidate: candidate,
           completion: completion
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
        max_response_bytes: transfer
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

  for hold <- [true, false] do
    test "held=#{hold} public resolution selects positive entered context and fences acceptance and completion" do
      {runtime, store, parent, child, usage, authority, context} = fixture(:normal, unquote(hold))
      assert {:ok, disposed} = resolve(runtime, child)
      assert disposed.state == :deleted and disposed.branch.state == :disposed
      assert disposed.created_machine == nil and disposed.observed_machine == nil
      assert disposed.branch.native_authority.completion == nil
      assert disposed.branch.native_authority.prepared_retirement == nil
      assert_receive {:store_write, :branch_advance, true}
      assert_receive {:store_write, :branch_resolve, true}
      assert Agent.get(authority, & &1) == nil
      assert_receive {:quiesce, :ok}
      events = calls()

      assert Enum.map(events, &elem(&1, 1)) ==
               ~w(retire_prepared_branch inspect_unbooted_branch_disposal dispose_unbooted_branch inspect)

      for {_, _, frozen, quiesced, epoch, _, _} <- events do
        assert frozen and quiesced and epoch == context.epoch
      end

      {_, _, _, _, _, operation, _} = Enum.at(events, 2)
      assert operation["request"] == disposed.branch.native_authority.disposal.request

      assert Contract.fetch(Memory, store, parent).native_branch_history[child.id].receipt ==
               disposed.branch.native_authority.disposal.proof.publication["receipt"]

      assert {:ok, after_usage} = Memory.usage(store, parent.worker_id)

      assert after_usage ==
               Map.merge(usage, Profile.resources(child.spec.profile), fn _, total, ordinary ->
                 total - ordinary
               end)

      assert {:ok, <<"smolbox-record-v37", 0, _::binary>>} = Codec.encode(disposed)
      assert {:ok, ^disposed} = resolve(runtime, child)
      refute_receive {:quiesce, _}
      assert calls() == []
    end
  end

  for mode <- [
        :missing_candidate,
        :invalid_candidate,
        :accept_failure,
        :stale_epoch,
        :stale_before_accept
      ] do
    test "#{mode} cannot accept disposal or dispatch native deletion" do
      {runtime, store, parent, child, usage, authority, context} = fixture(unquote(mode))
      assert {:error, _} = resolve(runtime, child)
      assert Contract.fetch(Memory, store, child).branch.native_authority.disposal == nil
      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      refute Enum.any?(calls(), &(elem(&1, 1) == "dispose_unbooted_branch"))
      assert Agent.get(authority, & &1) == nil
      assert Process.alive?(context.server)

      if unquote(mode) == :stale_before_accept,
        do: assert_receive({:store_write, :branch_advance, true})
    end
  end

  for mode <- [:wrong_source, :stale_child, :store_failure] do
    test "#{mode} preserves the accepted identity source lock ordinary capacity and backing" do
      {runtime, store, parent, child, usage, authority, _} = fixture(unquote(mode))
      assert {:error, %Error{evidence: :dispatch_uncertain}} = resolve(runtime, child)
      saved = Contract.fetch(Memory, store, child)

      assert saved.branch.state == :disposal_pending and
               saved.branch.native_authority.disposal.proof == nil

      assert saved.branch.native_authority.disposal.request["creation"] ==
               child.branch.native_authority.request

      assert Contract.fetch(Memory, store, parent).active_branch == child.id
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Agent.get(authority, & &1) == nil
    end
  end

  test "a lost disposal reply retains the same request and explicit retry only observes its original completion" do
    {runtime, store, parent, child, usage, _, _} = fixture(:lost_disposal)
    assert {:error, %Error{evidence: :dispatch_uncertain}} = resolve(runtime, child)
    pending = Contract.fetch(Memory, store, child)
    intent = pending.branch.native_authority.disposal
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    assert Enum.count(calls(), &(elem(&1, 1) == "dispose_unbooted_branch")) == 1
    assert {:ok, disposed} = resolve(runtime, child)
    assert disposed.branch.native_authority.disposal.request == intent.request
    assert Enum.map(calls(), &elem(&1, 1)) == ~w(resolve_unbooted_branch_disposal inspect)
  end

  test "accepted but unentered intent tries original observation before the same one-shot dispatch" do
    {runtime, store, parent, child, _, _, _} = fixture()
    assert {:ok, accepted} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    intent = accepted.branch.native_authority.disposal
    assert {:ok, disposed} = resolve(runtime, accepted)
    assert disposed.branch.native_authority.disposal.request == intent.request

    assert Enum.map(calls(), &elem(&1, 1)) ==
             ~w(resolve_unbooted_branch_disposal dispose_unbooted_branch inspect)
  end

  test "retained resolution remains available while draining and all stage allowances fit the original budget" do
    {runtime, _, _, child, _, _, _} = fixture(:draining)
    assert {:ok, _} = resolve(runtime, child)
    events = calls()
    # The final source observation consumes only what remains of disposal's
    # already offered allowance; exclude it when summing independent stages.
    stages = Enum.reject(events, &(elem(&1, 1) == "inspect"))
    assert Enum.reduce(stages, 0, &(elem(&1, 6).max_request_bytes + &2)) <= 262_144
    assert Enum.reduce(stages, 0, &(elem(&1, 6).max_response_bytes + &2)) <= 262_144
    assert Enum.all?(events, &(elem(&1, 6).timeout_ms <= 1000))
  end

  test "a spent transfer budget cannot accept disposal even after an entered retirement error" do
    {runtime, store, _, child, _, _, _} = fixture(:normal, true, 1000, 1024)
    assert {:error, %Error{category: :output_limit}} = resolve(runtime, child)
    assert Contract.fetch(Memory, store, child).branch.native_authority.disposal == nil
    assert Enum.map(calls(), &elem(&1, 1)) == ["retire_prepared_branch"]
  end
end
