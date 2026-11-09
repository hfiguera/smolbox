defmodule SmolBox.NativeCaptureHistoryTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    CaptureTransition,
    GrowthTransition,
    HistoricalExecution,
    Identity,
    MaterialHistory,
    NativeGrowth
  }

  alias SmolBox.Store.{CaptureOps, Codec, MachineOps, Memory, NativeCaptureContract}

  alias SmolBox.{
    CheckpointCapture,
    CheckpointCaptureSpec,
    CheckpointPolicy,
    CheckpointResult,
    Command,
    Execution,
    ExecutionSpec,
    ManagedMachine
  }

  defp proofs do
    "../../native/smolbox-protocol/fixtures/material-history-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn wire ->
      {:ok, proof} =
        if Map.has_key?(wire["change"], "intent"),
          do: CaptureTransition.from_wire(wire),
          else: GrowthTransition.from_wire(wire)

      proof
    end)
  end

  defp capture_proofs do
    "../../native/smolbox-protocol/fixtures/capture-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn wire ->
      {:ok, proof} = CaptureTransition.from_wire(wire)
      proof
    end)
  end

  defp fixture, do: NativeCaptureContract.fixture()

  defp capture(record, proof, now) do
    identity = record.observed_machine.backend_identity

    observed = %{
      record.observed_machine
      | state: :running,
        backend_identity: %{identity | pid_identity: [123, 456]}
    }

    record = %{record | state: :running, observed_machine: observed}
    assert :ok = ManagedMachine.validate(record)

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "private",
        root: "/operator/captures",
        max_bytes: 1_048_576,
        resources: %{slots: 1, cpus: 1, memory_mb: 256, disk_gb: 16}
      )

    {:ok, spec} =
      CheckpointCaptureSpec.new(
        id: proof.change["intent"]["operation_id"],
        policy: policy,
        idle: true
      )

    fingerprint =
      CheckpointCaptureSpec.fingerprint(
        spec,
        ManagedMachine.key(record),
        String.duplicate("k", 32)
      )

    assert {:ok, accepted} =
             CaptureOps.accept(
               record,
               spec,
               fingerprint,
               %{slots: 4, cpus: 8, memory_mb: 4096, disk_gb: 64},
               record.reservation,
               now
             )

    assert {:ok, sent} =
             CaptureOps.advance(accepted, spec.id, :accepted, [state: :dispatching], now + 1)

    result = %CheckpointResult{
      path: CheckpointCapture.path(sent.captures[spec.id]),
      sha256: proof.change["artifact"]["sha256"],
      size_bytes: 512,
      profile: SmolBox.DiskExpansion.profile(record),
      platform: :macos,
      architecture: "aarch64",
      runtime_version: "1.22.0"
    }

    assert {:error, _} =
             CaptureOps.advance(
               sent,
               spec.id,
               :dispatching,
               [state: :captured, result: result],
               now + 2
             )

    assert {:ok, captured} =
             CaptureOps.advance(
               sent,
               spec.id,
               :dispatching,
               [state: :captured, result: result, native_transition: proof],
               now + 2
             )

    assert captured.created_machine == record.created_machine
    assert captured.observed_machine.backend_identity.receipt == proof.receipt

    assert {:ok, completed} =
             CaptureOps.resolve(captured, spec.id, captured.observed_machine, now + 3)

    completed
  end

  test "one chain preserves growth capture growth order geometry and attached-command authority" do
    [first, middle, last] = history = proofs()
    sizes = %{"storage_gib" => 1, "overlay_gib" => 1}

    assert {:ok, receipt, %{"storage_gib" => 3, "overlay_gib" => 2}} =
             MaterialHistory.chain(history, first.previous, sizes)

    assert receipt == last.receipt
    assert :error = MaterialHistory.chain([first, last], first.previous, sizes)
    assert :error = MaterialHistory.chain([middle, first, last], first.previous, sizes)
    assert :error = MaterialHistory.chain(history ++ [last], first.previous, sizes)
    original = fixture()
    [first_capture, second_capture] = capture_proofs()
    captured = capture(original, first_capture, 1200)
    captured = capture(captured, second_capture, 1300)
    assert :ok = ManagedMachine.validate(captured)
    assert captured.captures["capture-1"].result.profile.storage_gb == 1
    assert {:ok, identity} = NativeGrowth.current_identity(captured)
    assert identity.material_history == [first_capture, second_capture]
    assert Identity.valid?(identity)
    refute SmolBox.DiskExpansion.supported?(captured)
    assert {:ok, <<"smolbox-record-v26\0", _::binary>> = bytes} = Codec.encode(captured)
    assert {:ok, ^captured} = Codec.decode(bytes)
    {:ok, command} = Command.new(["/bin/true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: captured.scope,
        id: "attached",
        profile: captured.spec.profile,
        artifact: captured.spec.artifact,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1400)

    running = captured
    assert {:ok, _, attached} = MachineOps.attach(running, execution, 1400)

    assert attached.created_machine.backend_identity.material_history == [
             first_capture,
             second_capture
           ]

    assert :ok = Execution.validate(attached)
    assert {:ok, <<"smolbox-record-v24\0", _::binary>> = encoded} = Codec.encode(attached)
    assert {:ok, ^attached} = Codec.decode(encoded)
  end

  test "v24 rejects old-envelope smuggling and capture evidence cannot lose its ordered history" do
    [first, second] = capture_proofs()
    record = fixture() |> capture(first, 1200) |> capture(second, 1300)

    record = %{
      record
      | captures:
          Map.new(record.captures, fn {id, capture} ->
            {id, %{capture | native_source_receipt: nil}}
          end)
    }

    assert {:ok, <<"smolbox-record-v24\0", body::binary>> = bytes} = Codec.encode(record)

    for version <- 16..23,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    identity = record.observed_machine.backend_identity
    refute Identity.valid?(%{identity | material_history: nil})

    refute Identity.valid?(%{
             identity
             | material_history: Enum.reverse(identity.material_history)
           })

    assert {:error, _} =
             Codec.encode(put_in(record.observed_machine.backend_identity.material_history, nil))

    assert {:error, _} =
             Codec.encode(put_in(record.captures["capture-1"].native_transition, nil))

    assert {:error, _} =
             Codec.encode(%{
               record
               | spec: %{record.spec | checkpointable: false},
                 backend_assignment: %{
                   record.backend_assignment
                   | creation: Map.delete(record.backend_assignment.creation, "checkpointable")
                 }
             })
  end

  test "collected command snapshots retain capture prefixes without claiming the current source" do
    original = fixture()
    [first, second] = capture_proofs()
    before = historical_command(original, "before-capture")
    captured = capture(original, first, 1200)
    between = historical_command(captured, "between-captures")
    final = capture(captured, second, 1300)

    assert HistoricalExecution.matches?(before, final)
    assert HistoricalExecution.matches?(between, final)
    refute HistoricalExecution.matches?(between, original)
    refute HistoricalExecution.matches?(historical_command(final, "future-capture"), captured)
    refute HistoricalExecution.matches?(before, %{final | captures: %{}})
    refute HistoricalExecution.matches?(%{before | managed_machine: {"foreign", "source"}}, final)

    unknown = %{between | state: :unknown, evidence: :unknown, result: nil}
    assert HistoricalExecution.matches?(unknown, final)
    assert unknown.result == nil and unknown.cleanup == :complete
    assert before.result.exit_code == 7
    assert final.reservation == original.reservation
    assert final.created_machine == original.created_machine
  end

  defp historical_command(parent, id) do
    {:ok, command} = Command.new(["/bin/true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: parent.scope,
        id: id,
        profile: parent.spec.profile,
        artifact: parent.spec.artifact,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1400)
    assert {:ok, _, attached} = MachineOps.attach(%{parent | state: :running}, execution, 1401)

    completed = %{
      attached
      | state: :completed,
        evidence: :exited,
        collection: :complete,
        cleanup: :complete,
        result: %SmolBox.Result{exit_code: 7, stdout: <<0, 255>>, stderr: <<>>}
    }

    assert :ok = Execution.validate(completed)
    completed
  end

  test "Memory atomically saves capture proof and source identity while rejected proofs retain usage" do
    store = start_supervised!(Memory)
    NativeCaptureContract.run(Memory, store)
  end

  test "fresh BEAM safely decodes native capture transition and material history vocabulary" do
    [capture, _] = capture_proofs()
    record = fixture() |> capture(capture, 1200)
    assert {:ok, bytes} = Codec.encode(record)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-native-capture-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{captures: %{"capture-1" => %{native_transition: %SmolBox.Embedded.CaptureTransition{}}}, observed_machine: %{backend_identity: %{material_history: [_]}}}} -> IO.puts("fresh-capture")
      _ -> System.halt(1)
    end
    """

    assert {"fresh-capture\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
