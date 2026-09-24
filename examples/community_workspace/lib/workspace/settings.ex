defmodule Workspace.Settings do
  @moduledoc "Host-approved configuration; browser input never changes worker policy."
  alias SmolBox.{ArtifactStore.Directory, Client, GuestPaths, Profile, Worker}
  alias SmolBox.DurableHost.Store
  alias SmolBox.Runtime.WorkerConfig
  import Bitwise

  def home, do: Application.fetch_env!(:community_workspace, :home)
  def max_file_bytes, do: 16_777_216
  def runtime, do: Workspace.Runtime
  def scope, do: "workspace"

  def load do
    with {:ok, bytes} <- File.read(Path.join(home(), "settings.json")),
         {:ok, settings} <- Jason.decode(bytes),
         true <- valid?(settings),
         {:ok, fingerprint} <- key("fingerprint.key", 32),
         {:ok, encryption} <- key("encryption.key", 32),
         {:ok, _web} <- key("web.key", 64) do
      {:ok, Map.merge(settings, %{"fingerprint" => fingerprint, "encryption" => encryption})}
    else
      _ -> {:error, :setup_required}
    end
  end

  def build(s) do
    with true <- digest(s["image_path"]) == s["image_sha256"],
         {:ok, paths} <-
           GuestPaths.new(
             upload_roots: ["/app/project", "/home/dev/.config"],
             download_roots: ["/app/project", "/home/dev/.config"],
             workdir_roots: ["/app/project", "/home/dev"]
           ),
         {:ok, profile} <-
           Profile.new("community-workspace-v1",
             guest_paths: paths,
             storage_gb: 2,
             overlay_gb: 2,
             host_overhead_mb: 768,
             execution_ms: 660_000,
             max_output_bytes: 65_536,
             max_file_bytes: max_file_bytes(),
             max_total_file_bytes: 33_554_432
           ),
         {:ok, objects} <-
           Directory.new(Path.join(home(), "objects"), max_file_bytes: max_file_bytes()),
         {:ok, endpoint} <- Worker.new("workspace-worker", s["worker_url"], worker_options()),
         {:ok, client} <-
           Client.new(endpoint, guest_paths: paths, max_file_bytes: max_file_bytes()),
         artifact = %{
           "id" => "workspace-python-v1",
           "architecture" => s["architecture"],
           "sha256" => s["image_sha256"]
         },
         {:ok, worker} <-
           WorkerConfig.new(
             client: client,
             architecture: s["architecture"],
             platform: platform(s["platform"]),
             runtime_version: "1.17.0",
             profiles: [profile],
             artifacts: [Map.put(artifact, "path", s["image_path"])],
             allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768},
             capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 4}
           ),
         {:ok, store} <- Store.new(Workspace.Repo, s["partition"], s["encryption"]) do
      options = [
        name: runtime(),
        namespace: "sbxstudio",
        mode: :durable,
        store: {Store, store},
        artifact_store: {Directory, objects},
        fingerprint_key: s["fingerprint"],
        workers: [worker],
        poll_ms: 100,
        lease_ms: 2000
      ]

      {:ok,
       %{
         options: options,
         settings: s,
         store: store,
         objects: objects,
         client: client,
         profile: profile,
         artifact: artifact
       }}
    else
      _ -> {:error, :configuration_invalid}
    end
  rescue
    _ -> {:error, :configuration_invalid}
  end

  def digest(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp valid?(s) do
    is_map(s) and SmolBox.Validation.identifier?(s["partition"]) and
      is_binary(s["image_path"]) and Path.type(s["image_path"]) == :absolute and
      SmolBox.Validation.digest?(s["image_sha256"]) and valid_platform?(s) and
      is_integer(s["service_port"]) and s["service_port"] in 1024..65_535 and
      valid_preview?(s["preview_url"])
  end

  defp valid_platform?(s),
    do: s["architecture"] in ["aarch64", "x86_64"] and s["platform"] in ["macos", "linux"]

  defp valid_preview?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil and
      uri.fragment == nil
  end

  defp valid_preview?(_), do: false
  defp platform("macos"), do: :macos
  defp platform("linux"), do: :linux

  defp worker_options do
    [
      allow_insecure_loopback: true,
      operation_timeout_ms: 660_000,
      receive_timeout_ms: 655_000,
      max_request_bytes: max_file_bytes(),
      max_response_bytes: 33_554_432
    ]
    |> optional(:token, "SMOLBOX_PROXY_TOKEN")
    |> optional(:unix_socket, "SMOLBOX_RUNTIME_SOCKET")
  end

  defp optional(options, key, variable) do
    case System.get_env(variable) do
      nil -> options
      value -> Keyword.put(options, key, value)
    end
  end

  defp key(name, size) do
    path = Path.join(home(), name)

    with {:ok, %{type: :regular, size: ^size, mode: mode}} <- File.lstat(path),
         true <- band(mode, 0o077) == 0,
         do: File.read(path)
  end
end
