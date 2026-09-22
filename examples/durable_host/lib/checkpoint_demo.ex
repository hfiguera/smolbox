defmodule SmolBox.DurableHost.CheckpointDemo do
  @moduledoc "Durable execution from the approved idle shell checkpoint fixture."
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Checkpoint, Client, Command, ExecutionSpec, Files, Profile, Worker}
  alias SmolBox.Example.Setup
  alias SmolBox.Runtime.WorkerConfig

  @input "staged\n"
  @program """
  set -eu
  printf x >> /workspace/count
  cat /dev/shm/smolbox-marker /workspace/baseline /workspace/input > /workspace/report
  echo changed > /dev/shm/smolbox-marker
  echo changed > /workspace/baseline
  cat /workspace/report
  """

  def environment do
    %{
      "source" => "checkpoint",
      "checkpoint_path" => System.fetch_env!("SMOLBOX_CHECKPOINT_PATH"),
      "checkpoint_sha256" => System.fetch_env!("SMOLBOX_CHECKPOINT_SHA256"),
      "socket" => System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET"),
      "artifact_root" => System.fetch_env!("SMOLBOX_ARTIFACT_ROOT"),
      "fingerprint_key_file" => System.fetch_env!("SMOLBOX_FINGERPRINT_KEY_FILE"),
      "encryption_key_file" => System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"),
      "partition" => System.fetch_env!("SMOLBOX_STORE_PARTITION"),
      "id" => System.fetch_env!("SMOLBOX_EXECUTION_ID")
    }
  end

  def build(settings, store, mode, name) do
    # This example runs beside the worker. Remote hosts need their own catalog
    # verification; a matching digest alone does not approve captured processes.
    true = Setup.digest_file(settings["checkpoint_path"]) == settings["checkpoint_sha256"]
    platform = if :os.type() == {:unix, :darwin}, do: :macos, else: :linux

    architecture =
      :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") |> hd()

    {:ok, profile} = Profile.new("durable-idle-shell-v1", preparation_ms: 60_000)

    {:ok, checkpoint} =
      Checkpoint.new(
        runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.17.0"),
        id: "idle-shell-v1",
        path: settings["checkpoint_path"],
        sha256: settings["checkpoint_sha256"],
        platform: platform,
        architecture: architecture,
        profile: profile
      )

    {:ok, endpoint} =
      Worker.new("checkpoint-example-worker", "http://localhost",
        unix_socket: settings["socket"],
        operation_timeout_ms: 60_000,
        receive_timeout_ms: 55_000
      )

    {:ok, client} = Client.new(endpoint)

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        platform: platform,
        architecture: architecture,
        runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.17.0"),
        artifacts: [],
        checkpoints: [checkpoint],
        profiles: [profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
      )

    {:ok, objects} = Directory.new(settings["artifact_root"])
    :ok = Directory.seed(objects, "checkpoint-example", "input-v1", @input)
    {:ok, command} = Command.new(["/bin/sh", "-c", @program], timeout_secs: 5)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "checkpoint-example",
        id: settings["id"],
        artifact: Checkpoint.artifact(checkpoint),
        profile: profile,
        command: command,
        retention_ms: 60_000,
        inputs: [
          %{
            "source" => "input-v1",
            "path" => "/workspace/input",
            "size" => byte_size(@input),
            "sha256" => Files.sha256(@input),
            "mode" => "runtime_default"
          }
        ],
        outputs: [
          %{"destination" => "report", "path" => "/workspace/report", "max_bytes" => 64},
          %{"destination" => "count", "path" => "/workspace/count", "max_bytes" => 32}
        ]
      )

    options = [
      name: name,
      namespace: "ckdurable",
      mode: mode,
      store: store,
      artifact_store: {Directory, objects},
      fingerprint_key: Setup.key(settings["fingerprint_key_file"]),
      workers: [worker],
      poll_ms: 100,
      lease_ms: 2000
    ]

    {options, spec, objects}
  end

  def verify_outputs(objects, handle) do
    {:ok, "warm\nbaseline\nstaged\n"} = Directory.read_output(objects, handle, "report", 64)
    {:ok, "x"} = Directory.read_output(objects, handle, "count", 32)
    :ok
  end
end
