defmodule SmolBox.NativeBranchControlReadinessTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}
  alias SmolBox.Embedded.Config
  alias SmolBox.Error
  alias SmolBox.Runtime.{Coordinator, NativeAuthority, NativeResolution, Target}
  alias SmolBox.Store.{CaptureOps, Memory, NativeCaptureContract}

  defmodule Clock do
    def now, do: 1400
  end

  # Real coordinator fencing handlers, without tasks, SDK or helper processes.
  defmodule Host do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(message, from, state), do: Coordinator.handle_call(message, from, state)
  end

  defmodule Store do
    def claim_worker({memory, flags, observer}, id, owner, now, ttl) do
      state = Agent.get_and_update(flags, fn s -> {s, %{s | calls: s.calls + 1}} end)
      count = state.calls + 1
      send(observer, {:lease, count})

      cond do
        state.fail_at == count -> {:error, %Error{category: :stale_claim, operation: :lease}}
        state.bump_at == count -> Memory.claim_worker(memory, id, owner, now + ttl + 1, ttl)
        true -> Memory.claim_worker(memory, id, owner, now, ttl)
      end
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, _), do: true
    def invoke(_, _, _, _), do: raise("the readiness model never dispatches SDK work")
    def pin(context, _), do: {:ok, context}
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call({:update, values}, _, state), do: {:reply, :ok, Map.merge(state, values)}
    def handle_call(:snapshot, _, state), do: {:reply, state, state}

    def handle_call(:health, _, state) do
      {:reply,
       {:ok,
        %{
          status: state.status,
          epoch: state.epoch,
          target_id: state.config.id,
          generation: state.config.domain_generation,
          package_identity: state.identity,
          package_manifest_sha256: state.config.package_manifest_sha256
        }}, state}
    end

    def handle_call({:quiesce, epoch}, from, state) do
      send(state.observer, {:quiesce, epoch})

      if epoch == state.epoch do
        status = if state.status == :quarantined, do: :quarantined, else: :reconciling

        if state.busy > 0 do
          failure = %Error{
            category: :admission_exhausted,
            operation: :embedded,
            evidence: state.busy_evidence
          }

          next = %{state | status: status, busy: state.busy - 1, epoch: state.busy_epoch || epoch}
          {:reply, {:error, failure}, next}
        else
          reply(from, state.quiesce_delay, :ok, %{state | status: status})
        end
      else
        {:reply, {:error, %Error{category: :identity_conflict, operation: :embedded}}, state}
      end
    end

    def handle_call({:activate, binding, epoch}, from, state) do
      send(state.observer, {:activate, binding, epoch})

      if state.activation_error or epoch != state.epoch or
           binding != Config.domain_binding(state.config) do
        {:reply, {:error, %Error{category: :identity_conflict, operation: :embedded}}, state}
      else
        status = if state.quarantine_after_activation, do: :quarantined, else: :ready
        reply(from, state.activation_delay, :ok, %{state | status: status})
      end
    end

    def handle_info({:deferred_reply, from, result}, state) do
      GenServer.reply(from, result)
      {:noreply, state}
    end

    defp reply(_from, 0, result, state), do: {:reply, result, state}

    defp reply(from, delay, result, state) do
      Process.send_after(self(), {:deferred_reply, from, result}, delay)
      {:noreply, state}
    end
  end

  defp fixture(options \\ []) do
    memory = start_supervised!(Memory)

    flags =
      start_supervised!(
        {Agent,
         fn -> %{calls: 0, fail_at: options[:fail_lease], bump_at: options[:bump_lease]} end}
      )

    native =
      struct(Config,
        id: options[:id] || "ordinary-control",
        domain_generation: String.duplicate("a", 32),
        package_identity: %{"model" => "original"},
        package_manifest_sha256: String.duplicate("1", 64)
      )

    epoch = String.duplicate("b", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           observer: self(),
           config: native,
           identity: native.package_identity,
           epoch: epoch,
           status: options[:status] || :ready,
           activation_error: options[:activation_error] || false,
           quarantine_after_activation: options[:quarantine_after_activation] || false,
           quiesce_delay: options[:quiesce_delay] || 0,
           activation_delay: options[:activation_delay] || 0,
           busy: Keyword.get(options, :busy, 0),
           busy_evidence: Keyword.get(options, :busy_evidence, :not_dispatched),
           busy_epoch: options[:busy_epoch]
         }}
      )

    context = %EmbeddedContext{config: native, server: peer, epoch: epoch, pinned: true}

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: native.id,
      context: context,
      budget: %Budget{timeout_ms: 5000, max_request_bytes: 131_072, max_response_bytes: 131_072}
    }

    target = %Target{
      id: native.id,
      kind: :embedded,
      connection: reference,
      domain_binding: Config.domain_binding(native)
    }

    config = %{
      workers: [target],
      store: {Store, {memory, flags, self()}},
      owner: "owner",
      clock: Clock,
      lease_ms: 10_000
    }

    frozen = if options[:incomplete_scan], do: MapSet.new([native.id]), else: MapSet.new()

    host =
      start_supervised!(
        {Host, %{config: config, task_targets: %{}, native_holders: %{}, native_frozen: frozen}}
      )

    %{
      host: host,
      config: config,
      target: target,
      peer: peer,
      flags: flags,
      record: %{created_machine: :known, worker_generation: options[:record_generation] || 1},
      memory: memory
    }
  end

  defp run(f, function, operation \\ :branch_retire, deadline \\ nil) do
    disposition =
      cond do
        operation in [:branch_retire, :branch_release_storage, :branch_resolve_ready] ->
          {:ordinary_branch, operation}

        operation == :capture_complete ->
          {:ordinary_capture, operation}

        true ->
          operation
      end

    NativeResolution.run(f.config, f.host, f.record, f.target, disposition, function, deadline)
  end

  defp capture_fixture(options \\ []) do
    f = fixture(Keyword.put(options, :id, "fixture-local"))

    {_original, _running, sent, spec, proof, _capacity, _usage} =
      NativeCaptureContract.prepare(Memory, f.memory)

    result = %SmolBox.CheckpointResult{
      path: SmolBox.CheckpointCapture.path(sent.captures[spec.id]),
      sha256: proof.change["artifact"]["sha256"],
      size_bytes: proof.change["artifact"]["size_bytes"],
      profile: sent.spec.profile,
      platform: :macos,
      architecture: "aarch64",
      runtime_version: "1.22.0"
    }

    {:ok, captured} =
      CaptureOps.advance(
        sent,
        spec.id,
        :dispatching,
        [state: :captured, result: result, native_transition: proof],
        1102
      )

    {:ok, completed} = CaptureOps.resolve(captured, spec.id, captured.observed_machine, 1103)
    {%{f | record: captured}, completed.captures[spec.id]}
  end

  test "completed capture preserves the same ready scan and returns its exact committed evidence" do
    {f, capture} = capture_fixture()

    assert {:ok, ^capture} =
             run(
               f,
               fn target ->
                 assert target.connection.context.quiesced
                 refute NativeAuthority.available?(f.host, f.target.id)
                 send(self(), :capture_completed_once)
                 {:ok, capture}
               end,
               :capture_complete
             )

    assert_received :capture_completed_once
    refute_received :capture_completed_once
    assert_received {:lease, 1}
    assert_received {:lease, 2}
    assert_received {:activate, _, _}
    assert NativeAuthority.activity(f.host, f.target.id) == %{ready: true, held: false}
  end

  for alteration <- [:untyped, :unknown, :fingerprint, :version, :transition, :machine] do
    test "capture completion cannot activate from #{alteration} evidence" do
      {f, capture} = capture_fixture()

      result =
        case unquote(alteration) do
          :untyped ->
            {:ok, :completed}

          :unknown ->
            {:error, %Error{category: :unknown, operation: :checkpoint, evidence: :unknown}}

          :fingerprint ->
            {:ok, %{capture | fingerprint: String.duplicate("f", 64)}}

          :version ->
            {:ok, %{capture | version: capture.version + 1}}

          :transition ->
            {:ok, %{capture | native_transition: nil}}

          :machine ->
            {:ok, %{capture | machine: {"foreign", "source"}}}
        end

      assert ^result = run(f, fn _ -> result end, :capture_complete)
      refute NativeAuthority.available?(f.host, f.target.id)
      refute_received {:activate, _, _}
    end
  end

  for options <- [
        [incomplete_scan: true],
        [status: :reconciling],
        [activation_error: true],
        [fail_lease: 2],
        [bump_lease: 2]
      ] do
    test "capture completion with #{inspect(options)} preserves evidence without promoting readiness" do
      {f, capture} = capture_fixture(unquote(options))
      assert {:ok, ^capture} = run(f, fn _ -> {:ok, capture} end, :capture_complete)
      refute NativeAuthority.available?(f.host, f.target.id)
    end
  end

  for disposition <- [:branch, :stopped, :deleted] do
    test "generic #{disposition} resolution drains only before its original callback and stays frozen" do
      f = fixture(busy: 2)
      observer = self()

      assert {:ok, :resolved} =
               run(
                 f,
                 fn target ->
                   assert NativeAuthority.activity(f.host, f.target.id) == %{
                            ready: false,
                            held: true
                          }

                   assert target.connection.context.quiesced
                   assert target.connection.context.epoch == f.target.connection.context.epoch
                   assert target.connection.budget.timeout_ms <= 1000
                   send(observer, :generic_control_once)
                   {:ok, :resolved}
                 end,
                 unquote(disposition),
                 System.monotonic_time(:millisecond) + 1000
               )

      assert_received :generic_control_once
      refute_received :generic_control_once
      assert_received {:lease, 1}
      refute_received {:lease, 2}
      refute_received {:activate, _, _}
      refute NativeAuthority.available?(f.host, f.target.id)
    end
  end

  test "generic busy resolution cannot renew its captured deadline or reach store/native work" do
    f = fixture(busy: 10_000)

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             run(
               f,
               fn _ -> flunk("generic work before drain") end,
               :branch,
               System.monotonic_time(:millisecond) + 50
             )

    refute_received {:lease, _}
    refute_received {:activate, _, _}
    refute NativeAuthority.available?(f.host, f.target.id)
  end

  test "an expired generic resolution cannot quiesce, claim or enter its callback" do
    f = fixture()

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             run(
               f,
               fn _ -> flunk("expired generic callback entered") end,
               :branch,
               System.monotonic_time(:millisecond) - 1
             )

    refute_received {:quiesce, _}
    refute_received {:lease, _}
    refute_received {:activate, _, _}
  end

  for operation <- [:branch_retire, :branch_release_storage] do
    test "#{operation} preserves only the completed original-owner scan through quiescence and lease renewal" do
      f = fixture()
      parent = self()

      assert {:ok, :material_committed} =
               run(
                 f,
                 fn target ->
                   assert target.connection.context.quiesced
                   refute NativeAuthority.available?(f.host, f.target.id)

                   assert {:error, %{category: :admission_exhausted}} =
                            NativeAuthority.run(f.host, f.target.id, fn ->
                              flunk("overlapping authority")
                            end)

                   send(parent, :material_committed)
                   {:ok, :material_committed}
                 end,
                 unquote(operation)
               )

      assert_received {:quiesce, _}
      assert_received {:lease, 1}
      assert_received :material_committed
      assert_received {:lease, 2}
      assert_received {:activate, binding, epoch}
      assert binding == f.target.domain_binding and epoch == f.target.connection.context.epoch
      assert NativeAuthority.activity(f.host, f.target.id) == %{ready: true, held: false}
      assert GenServer.call(f.peer, :snapshot).status == :ready
    end
  end

  test "pre-dispatch rejection preserves a healthy scan without inventing a result" do
    f = fixture()
    error = {:error, %Error{category: :validation, operation: :branch}}
    assert ^error = run(f, fn _ -> error end)
    assert NativeAuthority.available?(f.host, f.target.id)
    assert_received {:activate, _, _}
  end

  for result <- [
        {:ok, :untyped},
        {:ok, %{branch: %{state: :ready}}},
        {:error, %Error{category: :validation, operation: :branch, evidence: :not_dispatched}}
      ] do
    test "ready-result recovery does not reactivate from #{inspect(result)}" do
      f = fixture()
      result = unquote(Macro.escape(result))
      assert ^result = run(f, fn _ -> result end, :branch_resolve_ready)
      refute NativeAuthority.available?(f.host, f.target.id)
      refute_received {:activate, _, _}
    end
  end

  test "incomplete startup cannot be promoted even after a successful explicit control" do
    f = fixture(incomplete_scan: true)
    assert {:ok, :known} = run(f, fn _ -> {:ok, :known} end)
    refute NativeAuthority.available?(f.host, f.target.id)
    refute_received {:activate, _, _}
    assert GenServer.call(f.peer, :snapshot).status == :reconciling
  end

  for status <- [:reconciling, :quarantined] do
    test "initial #{status} helper cannot borrow the coordinator's old ready flag" do
      f = fixture(status: unquote(status))
      assert {:ok, :known} = run(f, fn _ -> {:ok, :known} end)
      refute NativeAuthority.available?(f.host, f.target.id)
      refute_received {:activate, _, _}
    end
  end

  for field <- [:epoch, :identity] do
    test "changed #{field} after the control prevents original-owner activation" do
      f = fixture()

      value =
        if unquote(field) == :epoch,
          do: String.duplicate("c", 32),
          else: %{"model" => "replacement"}

      assert {:ok, :committed} =
               run(f, fn _ ->
                 :ok = GenServer.call(f.peer, {:update, %{unquote(field) => value}})
                 {:ok, :committed}
               end)

      refute NativeAuthority.available?(f.host, f.target.id)
      refute_received {:activate, _, _}
    end
  end

  for option <- [
        activation_error: true,
        quarantine_after_activation: true,
        fail_lease: 2,
        bump_lease: 2,
        record_generation: 2
      ] do
    test "#{inspect(option)} leaves committed evidence intact but cannot restore readiness" do
      f = fixture([unquote(option)])
      assert {:ok, :committed} = run(f, fn _ -> {:ok, :committed} end)
      assert NativeAuthority.activity(f.host, f.target.id) == %{ready: false, held: false}
    end
  end

  test "a denied initial worker lease admits neither work nor activation" do
    f = fixture(fail_lease: 1)
    assert {:error, %{category: :stale_claim}} = run(f, fn _ -> flunk("work without lease") end)
    refute NativeAuthority.available?(f.host, f.target.id)
    refute_received {:activate, _, _}
  end

  for evidence <- [:dispatch_uncertain, :unknown] do
    test "#{evidence} control never reactivates or changes the returned uncertainty" do
      f = fixture()

      error =
        {:error, %Error{category: :unknown, operation: :branch, evidence: unquote(evidence)}}

      assert ^error = run(f, fn _ -> error end)
      refute NativeAuthority.available?(f.host, f.target.id)
      refute_received {:activate, _, _}
    end
  end

  test "an expired captured deadline dispatches no control or activation" do
    f = fixture()

    assert {:error, %{category: :expired}} =
             run(
               f,
               fn _ -> flunk("expired work") end,
               :branch_retire,
               System.monotonic_time(:millisecond) - 1
             )

    refute NativeAuthority.available?(f.host, f.target.id)
    refute_received {:quiesce, _}
    refute_received {:activate, _, _}
  end

  test "expiry after a returned result cannot extend the activation deadline" do
    f = fixture()
    deadline = System.monotonic_time(:millisecond) + 2000

    assert {:ok, :committed} =
             run(
               f,
               fn _ ->
                 Process.sleep(max(0, deadline - System.monotonic_time(:millisecond) + 10))
                 {:ok, :committed}
               end,
               :branch_release_storage,
               deadline
             )

    refute NativeAuthority.available?(f.host, f.target.id)
    refute_received {:activate, _, _}
  end

  for {phase, option} <- [quiesce: :quiesce_delay, activation: :activation_delay] do
    test "a delayed #{phase} reply cannot extend the captured control budget" do
      f = fixture([{unquote(option), 5000}])

      started = System.monotonic_time(:millisecond)
      result = run(f, fn _ -> {:ok, :committed} end, :branch_retire, started + 500)

      if unquote(phase) == :quiesce,
        do: assert({:error, %{evidence: :dispatch_uncertain}} = result),
        else: assert(result == {:ok, :committed})

      assert System.monotonic_time(:millisecond) - started < 2500
      assert NativeAuthority.activity(f.host, f.target.id) == %{ready: false, held: false}
    end
  end

  test "generic uncertainty resolution keeps the original startup fence" do
    f = fixture()
    assert {:ok, :known} = run(f, fn _ -> {:ok, :known} end, :stopped)
    refute NativeAuthority.available?(f.host, f.target.id)
    refute_received {:activate, _, _}
  end

  test "draining final Port records waits under the original barrier and dispatches work once" do
    f = fixture(busy: 2)
    parent = self()

    assert {:ok, :committed} =
             run(f, fn _ ->
               assert NativeAuthority.activity(f.host, f.target.id) == %{ready: false, held: true}
               assert GenServer.call(f.peer, :snapshot).busy == 0
               send(parent, :native_work_once)
               {:ok, :committed}
             end)

    assert_received :native_work_once
    refute_received :native_work_once
    assert_received {:lease, 1}
    assert_received {:lease, 2}
    assert_received {:activate, _, _}
    assert NativeAuthority.available?(f.host, f.target.id)
  end

  test "persistent drain exhaustion cannot extend the deadline or reach store/native work" do
    f = fixture(busy: 10_000)

    assert {:error, %{category: :expired}} =
             run(
               f,
               fn _ -> flunk("work before drain") end,
               :branch_retire,
               System.monotonic_time(:millisecond) + 50
             )

    refute_received {:lease, _}
    refute_received {:activate, _, _}
    refute NativeAuthority.available?(f.host, f.target.id)
  end

  test "an uncertain quiesce reply is returned unchanged without another attempt" do
    f = fixture(busy: 2, busy_evidence: :dispatch_uncertain)

    assert {:error, %{category: :admission_exhausted, evidence: :dispatch_uncertain}} =
             run(f, fn _ -> flunk("uncertain drain") end)

    assert GenServer.call(f.peer, :snapshot).busy == 1
    refute_received {:lease, _}
    refute_received {:activate, _, _}
  end

  test "an epoch change while draining prevents work and reactivation" do
    f = fixture(busy: 2, busy_epoch: String.duplicate("c", 32))
    assert {:error, %{category: :identity_conflict}} = run(f, fn _ -> flunk("new epoch") end)
    refute_received {:lease, _}
    refute_received {:activate, _, _}
    refute NativeAuthority.available?(f.host, f.target.id)
  end

  test "ordinary controls do not clear persisted worker draining" do
    f = fixture()
    assert {:ok, control} = Memory.worker_control(f.memory, f.target.id)

    assert {:ok, _} =
             Memory.set_worker_mode(
               f.memory,
               f.target.id,
               :draining,
               control.version,
               Clock.now()
             )

    assert {:ok, :known} = run(f, fn _ -> {:ok, :known} end)
    assert NativeAuthority.available?(f.host, f.target.id)
    assert {:ok, %{mode: :draining}} = Memory.worker_control(f.memory, f.target.id)
  end
end
