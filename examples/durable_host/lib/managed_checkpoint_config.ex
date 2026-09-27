defmodule SmolBox.DurableHost.ManagedCheckpointConfig do
  @moduledoc false
  alias SmolBox.{
    Checkpoint,
    CheckpointPolicy,
    CheckpointResult,
    Client,
    ManagedMachineSpec,
    Profile,
    Runtime,
    Worker
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.Runtime.WorkerConfig

  def start(phase, options \\ []) do
    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    id = System.fetch_env!("SMOLBOX_CHECKPOINT_ID")
    handle = {"checkpoint-demo", id}

    {:ok, profile} =
      Profile.new("capture-demo",
        cpus: 1,
        memory_mb: 256,
        storage_gb: 1,
        overlay_gb: 1,
        host_overhead_mb: 768,
        preparation_ms: 120_000,
        execution_ms: 120_000
      )

    seed = seed(profile)
    approval = approval(phase, store, handle)

    {:ok, endpoint} =
      Worker.new("checkpoint-worker", System.fetch_env!("SMOLBOX_WORKER_URL"),
        allow_insecure_loopback: System.get_env("SMOLBOX_ALLOW_LOOPBACK") == "true",
        operation_timeout_ms: 900_000,
        receive_timeout_ms: 900_000
      )

    {:ok, client} = Client.new(endpoint)

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "private-captures",
        root: System.fetch_env!("SMOLBOX_CAPTURE_ROOT"),
        max_bytes: 1_073_741_824,
        resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 16}
      )

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        architecture: seed.architecture,
        platform: seed.platform,
        artifacts: [],
        checkpoints: [seed] ++ List.wrap(approval),
        profiles: [profile],
        checkpoint_policies: [policy],
        branch_policies: Keyword.get(options, :branch_policies, []),
        capacity:
          Keyword.get(options, :capacity, %{slots: 4, cpus: 4, memory_mb: 8192, disk_gb: 32}),
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768}
      )

    {:ok, objects} = Directory.new(System.fetch_env!("SMOLBOX_ARTIFACT_DIR"))

    {:ok, runtime} =
      Runtime.start_link(
        name: __MODULE__,
        namespace: "capture",
        store: {Store, store},
        mode: :durable,
        artifact_store: {Directory, objects},
        fingerprint_key: Setup.key(System.fetch_env!("SMOLBOX_FINGERPRINT_KEY_FILE")),
        workers: [worker],
        poll_ms: 50,
        lease_ms: 1000
      )

    wait_ready(runtime, System.monotonic_time(:millisecond) + 15_000)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(handle, 0),
        id: id,
        artifact: Checkpoint.artifact(seed),
        profile: profile,
        checkpointable: true
      )

    %{
      runtime: runtime,
      store: store,
      client: client,
      spec: spec,
      handle: handle,
      capture: {elem(handle, 0), id, "prepared"},
      policy: policy,
      approval: approval
    }
  end

  defp seed(profile) do
    path = System.fetch_env!("SMOLBOX_CHECKPOINT_SEED_PATH")
    digest = System.fetch_env!("SMOLBOX_CHECKPOINT_SEED_SHA256")
    true = Setup.digest_file(path) == digest

    {:ok, seed} =
      Checkpoint.new(
        id: "idle-seed",
        path: path,
        sha256: digest,
        profile: profile,
        platform: platform(),
        architecture: System.fetch_env!("SMOLBOX_ARCHITECTURE")
      )

    seed
  end

  defp approval("restore", store, handle) do
    {:ok, m} = Store.machine(store, :fetch, [handle])
    %{state: :completed, result: result} = m.captures["prepared"]
    # This example runs on the worker host; no implicit transfer or remote path assumption.
    true = result.sha256 == System.fetch_env!("SMOLBOX_APPROVED_CHECKPOINT_SHA256")
    true = Setup.digest_file(result.path) == result.sha256
    {:ok, approval} = CheckpointResult.approval(result, id: "prepared", worker_path: result.path)
    approval
  end

  defp approval(_, _, _), do: nil

  defp platform do
    case System.fetch_env!("SMOLBOX_PLATFORM") do
      "linux" -> :linux
      "macos" -> :macos
    end
  end

  defp wait_ready(runtime, deadline) do
    case SmolBox.workers(runtime) do
      {:ok, [%{status: :ready}]} ->
        :ok

      _ ->
        true = System.monotonic_time(:millisecond) < deadline
        Process.sleep(50)
        wait_ready(runtime, deadline)
    end
  end
end
