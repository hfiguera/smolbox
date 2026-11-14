# Manual only. The settings file is trusted host code returning the map described
# in docs/kubernetes-backend.md; it is never supplied by an execution or guest.
defmodule SmolBox.KubernetesBackendSmoke do
  @moduledoc false
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Command, ExecutionSpec, Files, Source}
  alias SmolBox.Kubernetes.CleanupProof
  alias SmolBox.Store.Codec

  def main([settings_file, mode, id])
      when mode in ["binary", "silent", "cancel", "overflow", "resume", "crash", "lost", "reject"] do
    {settings, _} = Code.eval_file(Path.expand(settings_file))
    {:ok, artifacts} = Directory.new(settings.artifact_root)
    {:ok, runtime} = SmolBox.Runtime.start_link(options(settings, artifacts))

    try do
      handle = {"kubernetes-smoke", id}

      submit(runtime, settings, artifacts, mode, id, handle)

      {:ok, _terminal} = SmolBox.await(runtime, handle, 180_000)

      {:ok, record} =
        wait_clean(
          runtime,
          handle,
          System.monotonic_time(:millisecond) + 240_000,
          settings.report_root
        )

      verify(record, mode, artifacts)
      {adapter, context} = settings.store
      {:ok, %{slots: 0} = usage} = adapter.usage(context, settings.target.id)

      report = report(record, mode, handle, usage)

      File.write!(
        Path.join(settings.report_root, id <> ".json"),
        Jason.encode!(report, pretty: true)
      )

      IO.puts("Public #{mode} passed: #{record.state}, cleanup complete, zero reserved slots")
    after
      Supervisor.stop(runtime, :normal, 10_000)
    end
  end

  defp submit(runtime, settings, artifacts, mode, id, handle) do
    unless mode == "resume" do
      spec = spec(settings.target, artifacts, mode, id)
      {:ok, ^handle} = SmolBox.submit(runtime, spec)
      if mode == "cancel", do: cancel_running(runtime, handle)
    end

    if mode == "crash" do
      wait_state(runtime, handle, :running, System.monotonic_time(:millisecond) + 120_000)
      {:ok, record} = SmolBox.fetch(runtime, elem(handle, 0), elem(handle, 1))

      File.write!(
        Path.join(settings.report_root, id <> "-boundary.json"),
        Jason.encode!(%{
          pid: System.pid(),
          pod_uid: record.backend_receipt.pod_uid,
          machine_name: record.machine_name,
          state: record.state
        })
      )

      IO.puts(
        "Crash boundary: original public command running; awaiting owned-process fault injection"
      )

      Process.sleep(120_000)
      raise "fault injection was not performed"
    end
  end

  defp report(record, mode, handle, usage) do
    %{
      mode: mode,
      execution: Tuple.to_list(handle),
      state: record.state,
      evidence: record.evidence,
      result_exit: record.result && record.result.exit_code,
      collection: record.collection,
      cleanup: record.cleanup,
      usage: usage,
      pod_uid: record.backend_receipt && record.backend_receipt.pod_uid,
      cleanup_proof_version: record.backend_cleanup && record.backend_cleanup.version,
      observer_epoch: record.backend_receipt && record.backend_receipt.observation.observer_epoch,
      artifacts: record.artifacts,
      result_stdout_sha256: record.result && Files.sha256(record.result.stdout),
      result_stderr_sha256: record.result && Files.sha256(record.result.stderr)
    }
  end

  def options(settings, artifacts),
    do: [
      name: __MODULE__,
      namespace: "kubepublic",
      mode: settings.mode,
      store: settings.store,
      artifact_store: {Directory, artifacts},
      workers: [settings.target],
      fingerprint_key: settings.fingerprint_key,
      max_active: 1,
      poll_ms: 250,
      lease_ms: 5000
    ]

  def spec(target, artifacts, mode, id) do
    bytes = :binary.copy(<<0, 255, 128, 17>>, 1088)
    :ok = Directory.seed(artifacts, "kubernetes-smoke", "binary-input", bytes)
    {:ok, command} = Command.new(program(mode))
    binary = mode == "binary"

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "kubernetes-smoke",
        id: id,
        artifact: Source.artifact(hd(target.sources)),
        profile: hd(target.profiles),
        command: command,
        retention_ms: 0,
        inputs:
          if(binary,
            do: [
              %{
                "source" => "binary-input",
                "path" => "/workspace/input",
                "size" => byte_size(bytes),
                "sha256" => Files.sha256(bytes),
                "mode" => "runtime_default"
              }
            ],
            else: []
          ),
        outputs:
          if(binary,
            do: [
              %{
                "destination" => "binary-output",
                "path" => "/workspace/output",
                "max_bytes" => byte_size(bytes)
              }
            ],
            else: []
          )
      )

    spec
  end

  defp program("binary"),
    do: [
      "python3",
      "-c",
      "import os,pathlib,sys; b=pathlib.Path('/workspace/input').read_bytes(); assert b==bytes([0,255,128,17])*1088; pathlib.Path('/workspace/output').write_bytes(b[::-1]); os.write(1,bytes([0,255,128])); os.write(2,bytes([128,0])); sys.exit(7)"
    ]

  defp program("silent"), do: ["python3", "-c", "pass"]

  defp program("reject"), do: program("silent")

  defp program("lost"),
    do: ["python3", "-c", "import os,time; os.write(1,b'fault-started'); time.sleep(120)"]

  defp program("crash"), do: program("cancel")

  defp program("cancel"),
    do: ["python3", "-c", "import os,time; os.write(1,b'started'); time.sleep(120)"]

  defp program("overflow"),
    do: ["python3", "-c", "import os,time; os.write(1,b'x'*2097152); time.sleep(120)"]

  defp cancel_running(runtime, {scope, id} = handle) do
    wait_state(runtime, handle, :running, System.monotonic_time(:millisecond) + 120_000)
    {:ok, _} = SmolBox.cancel(runtime, scope, id)
  end

  defp wait_state(runtime, {scope, id} = handle, state, deadline) do
    true = System.monotonic_time(:millisecond) < deadline

    case SmolBox.fetch(runtime, scope, id) do
      {:ok, %{state: ^state}} ->
        :ok

      _ ->
        Process.sleep(250)
        wait_state(runtime, handle, state, deadline)
    end
  end

  defp wait_clean(runtime, {scope, id} = handle, deadline, root) do
    true = System.monotonic_time(:millisecond) < deadline

    case SmolBox.fetch(runtime, scope, id) do
      {:ok, %{cleanup: :complete, reservation: nil} = record} ->
        {:ok, record}

      {:ok, record} ->
        snapshot(root, id, record)
        Process.sleep(500)
        wait_clean(runtime, handle, deadline, root)

      _ ->
        Process.sleep(500)
        wait_clean(runtime, handle, deadline, root)
    end
  end

  defp snapshot(root, id, record) do
    state = {record.state, record.cleanup, record.evidence}

    if Process.get(:last_observed_state) != state do
      IO.puts("Observed #{record.state}: cleanup #{record.cleanup}, evidence #{record.evidence}")
      Process.put(:last_observed_state, state)
    end

    {:ok, bytes} = Codec.encode(record)
    path = Path.join(root, id <> "-diagnostic.record")
    File.write!(path, bytes, [:binary, :sync])
    File.chmod!(path, 0o600)
  end

  defp verify(record, mode, artifacts) do
    true = CleanupProof.releasable?(record.backend_cleanup, record.backend_receipt)

    verify_result(record, mode, artifacts)
  end

  defp verify_result(record, "binary", artifacts) do
    true = record.state == :completed and record.result.exit_code == 7
    true = record.result.stdout == <<0, 255, 128>> and record.result.stderr == <<128, 0>>

    {:ok, bytes} =
      Directory.read_output(artifacts, {record.scope, record.id}, "binary-output", 4352)

    true = bytes == :binary.copy(<<17, 128, 255, 0>>, 1088)
  end

  defp verify_result(record, "silent", _) do
    true = record.state == :completed and record.result.exit_code == 0
    true = record.result.stdout == "" and record.result.stderr == ""
  end

  defp verify_result(record, "reject", _),
    do: true = record.state == :failed and record.result == nil

  defp verify_result(record, mode, _) when mode in ["cancel", "overflow", "resume", "lost"] do
    true = record.state == :unknown and record.result == nil
    true = record.evidence == :termination_confirmed
  end
end

SmolBox.KubernetesBackendSmoke.main(System.argv())
