defmodule SmolBox.DurableHost.ExportDemoConfig do
  @moduledoc false
  alias SmolBox.{
    Client,
    ExportDestination,
    ExportResult,
    ManagedMachineSpec,
    Profile,
    Runtime,
    Worker
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.Runtime.WorkerConfig

  defmodule Credentials do
    @moduledoc false
    @behaviour SmolBox.RegistryCredentials
    @impl true
    def fetch(files, reference) do
      with {:ok, path} <- Map.fetch(files, reference),
           {:ok, bytes} <- File.read(path),
           do: {:ok, String.trim(bytes)}
    end
  end

  def start(phase) do
    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    id = System.fetch_env!("SMOLBOX_EXPORT_ID")
    handle = {"export-demo", id}
    copy_source = copy_source(phase, store, handle)
    architecture = System.fetch_env!("SMOLBOX_ARCHITECTURE")

    artifact = %{
      "id" => "export-base",
      "path" => System.fetch_env!("SMOLBOX_EXPORT_BASE_PATH"),
      "sha256" => System.fetch_env!("SMOLBOX_EXPORT_BASE_SHA256"),
      "architecture" => architecture
    }

    {:ok, endpoint} =
      Worker.new("export-demo-worker", System.fetch_env!("SMOLBOX_WORKER_URL"),
        allow_insecure_loopback: loopback?(),
        receive_timeout_ms: 900_000,
        operation_timeout_ms: 900_000
      )

    {:ok, client} = Client.new(endpoint)

    {:ok, profile} =
      Profile.new("export-demo-v1",
        storage_gb: 2,
        overlay_gb: 2,
        host_overhead_mb: 768,
        preparation_ms: 120_000,
        execution_ms: 120_000
      )

    destination = destination()

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        architecture: architecture,
        platform: platform(),
        artifacts: [artifact],
        sources: List.wrap(copy_source),
        profiles: [profile],
        export_destinations: [destination],
        registry_credentials: {Credentials, credential_files()},
        capacity: %{slots: 3, cpus: 6, memory_mb: 8192, disk_gb: 256},
        allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768}
      )

    {:ok, objects} = Directory.new(System.fetch_env!("SMOLBOX_ARTIFACT_DIR"))

    {:ok, runtime} =
      Runtime.start_link(
        name: __MODULE__,
        namespace: "exportdemo",
        store: {Store, store},
        mode: :durable,
        artifact_store: {Directory, objects},
        fingerprint_key: Setup.key(System.fetch_env!("SMOLBOX_FINGERPRINT_KEY_FILE")),
        workers: [worker],
        poll_ms: 50,
        lease_ms: 1000
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(handle, 0),
        id: id,
        artifact: Map.delete(artifact, "path"),
        profile: profile
      )

    %{
      runtime: runtime,
      client: client,
      store: store,
      spec: spec,
      handle: handle,
      export_handle: {elem(handle, 0), id, "prepared"},
      destination: destination,
      copy_source: copy_source
    }
  end

  defp destination do
    {:ok, destination} =
      ExportDestination.new(
        id: "demo-exports",
        registry: System.fetch_env!("SMOLBOX_EXPORT_REGISTRY"),
        repository: System.fetch_env!("SMOLBOX_EXPORT_REPOSITORY"),
        credential_ref: "publisher",
        immutable_tags: true,
        allow_insecure_loopback: loopback?(),
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    destination
  end

  defp copy_source("reuse", store, handle) do
    {:ok, machine} = Store.machine(store, :fetch, [handle])
    %{state: :completed, result: result} = machine.exports["prepared"]
    true = result.reference == System.fetch_env!("SMOLBOX_APPROVED_EXPORT_REFERENCE")
    options = [id: "approved-export"]

    options =
      if System.get_env("SMOLBOX_EXPORT_READER_TOKEN_FILE"),
        do: Keyword.put(options, :credential_ref, "reader"),
        else: options

    {:ok, source} = ExportResult.source(result, options)
    source
  end

  defp copy_source(_phase, _store, _handle), do: nil

  defp credential_files do
    files = %{"publisher" => System.fetch_env!("SMOLBOX_EXPORT_TOKEN_FILE")}

    case System.get_env("SMOLBOX_EXPORT_READER_TOKEN_FILE") do
      nil -> files
      path -> Map.put(files, "reader", path)
    end
  end

  defp loopback?, do: System.get_env("SMOLBOX_ALLOW_LOOPBACK") == "true"

  defp platform do
    case System.fetch_env!("SMOLBOX_PLATFORM") do
      "linux" -> :linux
      "macos" -> :macos
    end
  end
end
