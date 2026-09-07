defmodule SmolBox.Runtime.WorkerConfig do
  @moduledoc """
  Host-approved managed worker, prepared artifacts, and exact profile revisions.

  Artifact entries have `id`, `sha256`, `architecture`, and an absolute prepared
  `.smolmachine` `path` on this worker. The operator verifies artifact digests,
  neutral `/bin/true` startup, disabled workload restart, and the pinned runtime
  before registering them. Managed admission compares the server-reported version
  and checks readiness; the worker API cannot attest artifact contents or isolation.

  The initial qualification is explicitly `:development`; it does not certify
  hostile multi-tenant host quotas. Requested unsupported hard controls are
  rejected by `SmolBox.Profile`. Reachability alone does not qualify a worker.
  """
  alias SmolBox.{Client, Error, ExecutionSpec, MachineSpec, Profile, Store, Validation}

  @enforce_keys [:client, :architecture, :platform, :artifacts, :profiles, :capacity]
  @derive {Inspect, only: [:architecture, :platform, :runtime_version, :qualification]}
  defstruct @enforce_keys ++
              [runtime_version: "1.14.1", qualification: :development, draining: false]

  @type t :: %__MODULE__{
          client: Client.t(),
          architecture: String.t(),
          platform: :linux | :macos,
          artifacts: [map()],
          profiles: [Profile.t()],
          capacity: Store.capacity(),
          runtime_version: String.t(),
          qualification: :development,
          draining: boolean()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys ++ [:runtime_version, :qualification, :draining]) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      worker = struct!(__MODULE__, options)
      with :ok <- validate(worker), do: {:ok, worker}
    else
      invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = worker) do
    if Validation.struct_shape?(worker, __MODULE__) and valid_fields?(worker),
      do: :ok,
      else: invalid()
  end

  def validate(_worker), do: invalid()

  @spec supports?(t(), ExecutionSpec.t()) :: boolean()
  def supports?(worker, spec) do
    spec.profile in worker.profiles and worker.architecture == spec.artifact["architecture"] and
      Enum.any?(
        worker.artifacts,
        &(Map.take(&1, ["id", "sha256", "architecture"]) == spec.artifact)
      )
  end

  @spec artifact_path(t(), ExecutionSpec.t()) :: String.t()
  def artifact_path(worker, spec) do
    Enum.find(
      worker.artifacts,
      &(Map.take(&1, ["id", "sha256", "architecture"]) == spec.artifact)
    )["path"]
  end

  defp valid_fields?(worker) do
    valid_client?(worker.client) and worker.runtime_version == "1.14.1" and
      worker.qualification == :development and valid_platform?(worker) and
      is_boolean(worker.draining) and capacity?(worker.capacity) and catalogs?(worker)
  end

  defp valid_client?(%Client{} = client) do
    Validation.struct_shape?(client, Client) and
      match?({:ok, _client}, Client.new(client.worker, transport: client.transport))
  end

  defp valid_client?(_client), do: false

  defp valid_platform?(worker),
    do:
      worker.architecture in ["x86_64", "aarch64"] and worker.platform in [:linux, :macos] and
        (worker.platform != :macos or worker.architecture == "aarch64")

  defp catalogs?(worker) do
    profiles?(worker.profiles) and Validation.list?(worker.artifacts, 32) and
      worker.artifacts != [] and Enum.all?(worker.artifacts, &artifact?(&1, worker.architecture)) and
      unique?(worker.artifacts, & &1["id"])
  end

  defp profiles?(profiles),
    do:
      Validation.list?(profiles, 32) and profiles != [] and
        Enum.all?(profiles, &(Profile.validate(&1) == :ok)) and unique?(profiles, & &1.id)

  defp artifact?(
         %{"id" => id, "sha256" => digest, "architecture" => arch, "path" => path} = artifact,
         arch
       ) do
    map_size(artifact) == 4 and Validation.identifier?(id) and Validation.digest?(digest) and
      match?({:ok, _machine}, MachineSpec.new("approved-artifact", path))
  end

  defp artifact?(_artifact, _architecture), do: false

  defp capacity?(capacity) do
    is_map(capacity) and Enum.sort(Map.keys(capacity)) == [:cpus, :disk_gb, :memory_mb, :slots] and
      Enum.all?(Map.values(capacity), &Validation.integer?(&1, 1, 1_048_576))
  end

  defp unique?(entries, function),
    do: MapSet.size(MapSet.new(entries, function)) == length(entries)

  defp invalid, do: {:error, %Error{category: :validation, operation: :runtime}}
end
