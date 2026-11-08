defmodule SmolBox.NativeCapturePublicReleaseTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext, Reference}

  alias SmolBox.Embedded.{
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    Config,
    Identity,
    NativeCapture,
    NativeCaptureCleanup
  }

  alias SmolBox.{CheckpointCapture, CheckpointResult, Checkpoints, ManagedMachine}
  alias SmolBox.Runtime.{Coordinator, Target, WorkSupervisor}
  alias SmolBox.Store.{Contract, Memory, NativeCaptureContract}

  defmodule Clock do
    def now, do: 1104
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:quiesce, epoch}, _, state) do
      send(state.parent, {:quiesce, epoch})

      result =
        cond do
          epoch != state.epoch ->
            {:error, %SmolBox.Error{category: :identity_conflict, operation: :checkpoint}}

          state.busy ->
            {:error, %SmolBox.Error{category: :admission_exhausted, operation: :checkpoint}}

          true ->
            :ok
        end

      {:reply, result, %{state | frozen: result == :ok}}
    end

    def handle_call({:cleanup, capture}, _, state) do
      send(state.parent, {:cleanup, capture.spec.id, state.frozen})

      receipt = %CaptureStagingCleanupReceipt{
        schema: 1,
        previous: capture.native_source_receipt,
        operation_id: capture.spec.id,
        request: NativeCapture.request(capture),
        stage_sha256: String.duplicate("e", 64)
      }

      proof = %NativeCaptureCleanup{kind: state.kind, receipt: receipt}

      result =
        case state.reply do
          :proof ->
            {:ok, proof}

          :foreign ->
            {:ok, %{proof | receipt: %{receipt | operation_id: "foreign"}}}

          :uncertain ->
            {:error,
             %SmolBox.Error{
               category: :unknown,
               operation: :checkpoint,
               evidence: :dispatch_uncertain
             }}
        end

      if state.partial do
        path = CheckpointCapture.path(capture) <> ".partial"
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "preserve")
      end

      {:reply, result, %{state | partial: false}}
    end
  end

  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :cleanup_capture
    def pin(context, _), do: {:ok, context}
    def assign(context, _), do: {:ok, context}

    def invoke(context, :cleanup_capture, [capture, true], _),
      do: GenServer.call(context.server, {:cleanup, capture})
  end

  defmodule Host do
    use GenServer
    def start_link(config), do: GenServer.start_link(__MODULE__, config)
    def init(config), do: {:ok, %{config: config, holder: nil}}
    def handle_call(:config, _, state), do: {:reply, {:ok, state.config}, state}

    def handle_call({:native_acquire, id}, {caller, _}, %{holder: nil} = state),
      do: {:reply, :ok, %{state | holder: {id, caller}}}

    def handle_call({:native_release, id}, {caller, _}, %{holder: {id, caller}} = state),
      do: {:reply, :ok, %{state | holder: nil}}
  end

  defp fixture(disposition, options \\ []) do
    store = start_supervised!(Memory)

    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-public-release-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    proofs =
      if disposition == :resolved,
        do: NativeCaptureContract.resolution_proofs(),
        else:
          Path.expand(
            "../../native/smolbox-protocol/fixtures/capture-transitions-v1.json",
            __DIR__
          )
          |> File.read!()
          |> Jason.decode!()
          |> Enum.map(fn wire ->
            {:ok, proof} = CaptureTransition.from_wire(wire)
            proof
          end)

    {_, _, sent, spec, proof, _, _} = NativeCaptureContract.prepare(Memory, store, proofs, root)
    record = capture_record(store, sent, spec, proof, disposition)

    epoch = String.duplicate("a", 32)

    peer =
      start_supervised!(
        {Peer,
         %{
           parent: self(),
           epoch: epoch,
           busy: options[:busy] || false,
           frozen: false,
           kind: if(disposition == :aborted, do: :aborted, else: :cleaned),
           reply: options[:reply] || :proof,
           partial: options[:partial] || false
         }}
      )

    context = %EmbeddedContext{
      config: struct(Config),
      server: peer,
      pinned: true,
      epoch: if(options[:stale_epoch], do: String.duplicate("f", 32), else: epoch)
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: record.worker_id,
      context: context,
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}
    }

    target = %Target{kind: :embedded, id: record.worker_id, connection: reference}

    config = %{
      managed_machines: true,
      store: {Memory, store},
      workers: [target],
      owner: "owner",
      clock: Clock,
      lease_ms: 10_000,
      poll_ms: 20
    }

    host = %{id: Coordinator, start: {Host, :start_link, [config]}}

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

    assert {:ok, usage} = Memory.usage(store, record.worker_id)
    {runtime, store, record, spec, usage}
  end

  defp capture_record(store, sent, spec, proof, disposition) do
    key = ManagedMachine.key(sent)

    case disposition do
      mode when mode in [:completed, :deleted] ->
        result = %CheckpointResult{
          path: CheckpointCapture.path(sent.captures[spec.id]),
          sha256: proof.change["artifact"]["sha256"],
          size_bytes: 512,
          profile: sent.spec.profile,
          platform: :macos,
          architecture: "aarch64",
          runtime_version: "1.22.0"
        }

        assert {:ok, captured} =
                 Memory.machine(store, :capture_advance, [
                   key,
                   Contract.guard(sent),
                   spec.id,
                   :dispatching,
                   [state: :captured, result: result, native_transition: proof],
                   1102
                 ])

        observed = if mode == :deleted, do: :absent, else: captured.observed_machine

        assert {:ok, record} =
                 Memory.machine(store, :capture_resolve, [
                   key,
                   Contract.guard(captured),
                   spec.id,
                   observed,
                   1103
                 ])

        record

      mode ->
        assert {:ok, unknown} =
                 Memory.machine(store, :capture_advance, [
                   key,
                   Contract.guard(sent),
                   spec.id,
                   :dispatching,
                   [state: :unknown],
                   1102
                 ])

        case mode do
          :unknown ->
            unknown

          :aborted ->
            assert {:ok, record} =
                     Memory.machine(store, :capture_resolve, [
                       key,
                       Contract.guard(unknown),
                       spec.id,
                       :absent,
                       1103
                     ])

            record

          :resolved ->
            assert %CaptureResolutionTransition{} = proof

            observed = %{
              unknown.observed_machine
              | state: :stopped,
                backend_identity: %Identity{
                  receipt: proof.receipt,
                  transition: proof,
                  material_history: [proof]
                }
            }

            assert {:ok, record} =
                     Memory.machine(store, :capture_resolve, [
                       key,
                       Contract.guard(unknown),
                       spec.id,
                       observed,
                       1103
                     ])

            record
        end
    end
  end

  for disposition <- [:completed, :resolved, :deleted, :aborted] do
    test "public #{disposition} release fences the same helper and atomically consumes exact native cleanup" do
      {runtime, store, record, spec, usage} = fixture(unquote(disposition))
      handle = {record.scope, record.id, spec.id}
      assert {:ok, capture} = Checkpoints.release(runtime, handle, artifacts_removed: true)
      assert_receive {:quiesce, _}
      assert_receive {:cleanup, id, true}
      assert id == spec.id
      assert capture.released_at_ms == Clock.now()

      assert capture.native_cleanup.receipt.previous ==
               record.captures[spec.id].native_source_receipt

      assert capture.result == record.captures[spec.id].result
      assert {:ok, after_usage} = Memory.usage(store, record.worker_id)
      assert after_usage.disk_gb == usage.disk_gb - 1
      assert {:ok, ^capture} = Checkpoints.release(runtime, handle, artifacts_removed: true)
      refute_receive {:cleanup, _, _}
      refute_receive {:quiesce, _}
    end
  end

  for options <- [[busy: true], [stale_epoch: true], [reply: :foreign], [reply: :uncertain]] do
    test "public release preserves accounting on #{inspect(options)}" do
      {runtime, store, record, spec, usage} = fixture(:resolved, unquote(options))

      assert {:error, _} =
               Checkpoints.release(runtime, {record.scope, record.id, spec.id},
                 artifacts_removed: true
               )

      assert {:ok, saved} = Memory.machine(store, :fetch, [ManagedMachine.key(record)])

      assert saved.captures[spec.id].released_at_ms == nil and
               saved.captures[spec.id].native_cleanup == nil

      assert {:ok, ^usage} = Memory.usage(store, record.worker_id)
    end
  end

  test "host partial output created during cleanup keeps accounting and is never deleted" do
    {runtime, store, record, spec, usage} = fixture(:resolved, partial: true)
    handle = {record.scope, record.id, spec.id}
    assert {:error, _} = Checkpoints.release(runtime, handle, artifacts_removed: true)
    path = CheckpointCapture.path(record.captures[spec.id]) <> ".partial"
    assert File.read!(path) == "preserve"
    assert {:ok, ^usage} = Memory.usage(store, record.worker_id)
    File.rm!(path)
    assert {:ok, _} = Checkpoints.release(runtime, handle, artifacts_removed: true)
  end

  test "unknown capture cannot invoke cleanup or unlock retained work" do
    {runtime, store, record, spec, usage} = fixture(:unknown)

    assert {:error, _} =
             Checkpoints.release(runtime, {record.scope, record.id, spec.id},
               artifacts_removed: true
             )

    refute_receive {:quiesce, _}
    refute_receive {:cleanup, _, _}
    assert {:ok, ^usage} = Memory.usage(store, record.worker_id)
  end
end
