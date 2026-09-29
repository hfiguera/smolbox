defmodule SmolBox.ProvisioningConfig do
  @moduledoc false
  alias SmolBox.{
    BranchPolicy,
    Checkpoint,
    CheckpointPolicy,
    Client,
    ExportDestination,
    Profile,
    Runtime,
    Worker
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{ExportDemoConfig, Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.Runtime.WorkerConfig

  def start(config) do
    {:ok, store} =
      Store.new(Repo, config["partition"], Setup.key(config["root"] <> "/encryption.key"))

    {:ok, profile} =
      Profile.new("provisioning",
        cpus: 1,
        memory_mb: 256,
        storage_gb: 1,
        overlay_gb: 1,
        host_overhead_mb: 768,
        preparation_ms: 120_000,
        execution_ms: 120_000
      )

    artifact = %{
      "id" => "bare-base",
      "architecture" => "x86_64",
      "path" => config["base_path"],
      "sha256" => Setup.digest_file(config["base_path"])
    }

    {:ok, endpoint} =
      Worker.new("benchmark", config["worker_url"],
        allow_insecure_loopback: true,
        operation_timeout_ms: 900_000,
        receive_timeout_ms: 900_000
      )

    {:ok, client} = Client.new(endpoint)
    version = Map.get(config, "runtime_version", "1.19.0")
    {:ok, %{version: ^version}} = Client.health(client)

    capture_root = config["root"] <> "/captures/" <> config["partition"]
    File.mkdir_p!(capture_root)
    File.chmod!(capture_root, 0o700)

    {:ok, capture} =
      CheckpointPolicy.new(
        id: "bench-captures",
        root: capture_root,
        max_bytes: 1_073_741_824,
        resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 16}
      )

    {:ok, branch} =
      BranchPolicy.new(
        id: "bench-branches",
        resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 8}
      )

    {:ok, export} =
      ExportDestination.new(
        id: "bench-exports",
        registry: config["registry"],
        repository: "team/exports",
        credential_ref: "publisher",
        immutable_tags: true,
        allow_insecure_loopback: true,
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    {:ok, seed} =
      Checkpoint.new(
        id: "seed",
        path: config["seed_path"],
        sha256: Setup.digest_file(config["seed_path"]),
        profile: profile,
        architecture: "x86_64",
        platform: :linux,
        runtime_version: version
      )

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        runtime_version: version,
        platform: :linux,
        architecture: "x86_64",
        artifacts: [artifact],
        profiles: [profile],
        checkpoint_policies: [capture],
        checkpoints: [seed],
        branch_policies: [branch],
        export_destinations: [export],
        registry_credentials:
          {ExportDemoConfig.Credentials, %{"publisher" => config["root"] <> "/publisher.token"}},
        capacity: %{slots: 8, cpus: 8, memory_mb: 8192, disk_gb: 256},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768}
      )

    base = %{
      config: config,
      store: store,
      profile: profile,
      artifact: Map.delete(artifact, "path"),
      worker: worker,
      client: client,
      capture_policy: capture,
      seed: Checkpoint.artifact(seed),
      branch_policy: branch,
      export_destination: export
    }

    boot(base)
  end

  def boot(c) do
    {:ok, objects} = Directory.new(c.config["root"] <> "/artifacts")

    {:ok, runtime} =
      Runtime.start_link(
        name: __MODULE__,
        namespace: "bench",
        mode: :durable,
        store: {Store, c.store},
        artifact_store: {Directory, objects},
        fingerprint_key: Setup.key(c.config["root"] <> "/fingerprint.key"),
        workers: [c.worker],
        poll_ms: 25,
        lease_ms: 1000
      )

    ready(runtime, System.monotonic_time(:millisecond) + 15_000)
    Map.put(c, :runtime, runtime)
  end

  defp ready(runtime, deadline) do
    case SmolBox.workers(runtime) do
      {:ok, [%{status: :ready}]} ->
        :ok

      _ ->
        true = System.monotonic_time(:millisecond) < deadline
        Process.sleep(25)
        ready(runtime, deadline)
    end
  end
end
