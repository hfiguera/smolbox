defmodule SmolBox.Runtime.WorkerConfig do
  @moduledoc """
  Host-approved managed worker, prepared artifacts, and exact profile revisions.

  Artifact entries have `id`, `sha256`, `architecture`, and an absolute prepared
  `.smolmachine` `path` on this worker. The operator verifies artifact digests,
  neutral `/bin/true` startup, disabled workload restart, and the pinned runtime
  before registering them. Managed admission compares the server-reported version
  and checks readiness; the worker API cannot attest artifact contents or isolation.

  `checkpoints` optionally registers `SmolBox.Checkpoint` approvals. Each binds
  an idle offline source to its exact profile, platform, architecture and 1.16.1
  runtime. `artifacts: []` is accepted when checkpoints are configured. Approval
  is supplied by the operator and is not remotely attested.

  `allocation_floor` is a required operator declaration with `storage_gb`,
  `overlay_gb`, and `host_overhead_mb`. It must cover the largest actual disk
  templates across this worker's runtime and approved artifacts, and its VMM
  overhead. smolvm 1.14.1 only grows disk templates: a smaller API request can
  still expose a larger guest disk. Admission rejects profiles below these
  floors. This declaration is not remotely attested or a host filesystem quota.

  Versions 1.14.6, 1.16.0 and 1.16.1 require working host `resize2fs` for disk requests below
  template sizes. Verify file persistence across stop/start before admission;
  see [Compatibility](compatibility.html#macos-1-14-6-prerequisites).

  The initial qualification is explicitly `:development`; it does not certify
  hostile multi-tenant host quotas. Requested unsupported hard controls are
  rejected by `SmolBox.Profile`. Reachability alone does not qualify a worker.
  """
  alias SmolBox.{
    Checkpoint,
    Client,
    Error,
    ExecutionSpec,
    MachineSpec,
    Profile,
    Store,
    Validation
  }

  @enforce_keys [
    :client,
    :architecture,
    :platform,
    :artifacts,
    :profiles,
    :capacity,
    :allocation_floor
  ]
  @derive {Inspect, only: [:architecture, :platform, :runtime_version, :qualification]}
  defstruct @enforce_keys ++
              [
                runtime_version: "1.16.1",
                qualification: :development,
                draining: false,
                checkpoints: []
              ]

  @type t :: %__MODULE__{
          client: Client.t(),
          architecture: String.t(),
          platform: :linux | :macos,
          artifacts: [map()],
          checkpoints: [Checkpoint.t()],
          profiles: [Profile.t()],
          capacity: Store.capacity(),
          allocation_floor: %{
            storage_gb: pos_integer(),
            overlay_gb: pos_integer(),
            host_overhead_mb: pos_integer()
          },
          runtime_version: String.t(),
          qualification: :development,
          draining: boolean()
        }

  @doc """
  Register a worker's approved artifacts, profiles, and admission capacity.

  Required keyword options:

  | Option | Value |
  |---|---|
  | `:client` | A validated `SmolBox.Client` |
  | `:platform` | `:linux` or `:macos`; initially qualified hosts are Linux x86_64 and macOS Apple Silicon |
  | `:architecture` | `"x86_64"` or `"aarch64"`; macOS requires `"aarch64"` |
  | `:artifacts` | 0–32 maps with exactly string keys `"id"`, `"sha256"`, `"architecture"`, and absolute worker `"path"` ending in `.smolmachine` |
  | `:profiles` | 1–32 valid `SmolBox.Profile` values with unique IDs |
  | `:capacity` | Atom-keyed map with `:slots`, `:cpus`, `:memory_mb`, and `:disk_gb`; each 1–1,048,576 |
  | `:allocation_floor` | Atom-keyed map with `:storage_gb` and `:overlay_gb` (1–64 each), and `:host_overhead_mb` (128–16,384) |

  Optional `:checkpoints` defaults to `[]` and accepts up to 32 unique
  `SmolBox.Checkpoint` approvals. At least one image or checkpoint is required.

  Other optional fields are `:runtime_version` (default `"1.16.1"` for Linux x86_64 or
  macOS Apple Silicon; explicitly select `"1.16.0"`, `"1.14.1"` or `"1.14.6"`
  for another supported worker), `:qualification`
  (only `:development`), and `:draining` (default `false`). Artifact IDs must be
  unique and architectures must match this worker. Construction makes no worker
  request or remote digest check. Profiles below the floor cannot support execution.
  SmolBox 0.1.4 defaults to 1.16.1; SmolBox 0.1.3 defaults
  to 1.16.0 and 0.1.2 to 1.14.6. See the
  [qualification evidence](compatibility.html#smolvm-1-16-1-qualification) and
  upgrade the separately installed worker or retain its explicit version.
  See [Getting started](getting-started.html) for a complete configuration.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(
         options,
         @enforce_keys ++ [:runtime_version, :qualification, :draining, :checkpoints]
       ) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      worker = struct!(__MODULE__, options)
      with :ok <- validate(worker), do: {:ok, worker}
    else
      invalid()
    end
  end

  @doc "Revalidate configuration shape, catalogs and declarations without contacting the worker."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = worker) do
    if Validation.struct_shape?(worker, __MODULE__) and valid_fields?(worker),
      do: :ok,
      else: invalid()
  end

  def validate(_worker), do: invalid()

  @doc "Check exact profile/artifact approval and allocation floors; this is not a health probe."
  @spec supports?(t(), ExecutionSpec.t()) :: boolean()
  def supports?(worker, %{artifact: %{"kind" => "checkpoint"}} = spec) do
    spec.profile in worker.profiles and allocation_fits?(worker, spec.profile) and
      Enum.any?(worker.checkpoints, fn checkpoint ->
        Checkpoint.artifact(checkpoint) == spec.artifact and checkpoint.profile == spec.profile
      end)
  end

  def supports?(worker, spec) do
    (spec.profile.network == :offline or worker.runtime_version in ["1.16.0", "1.16.1"]) and
      spec.profile in worker.profiles and allocation_fits?(worker, spec.profile) and
      worker.architecture == spec.artifact["architecture"] and
      Enum.any?(
        worker.artifacts,
        &(Map.take(&1, ["id", "sha256", "architecture"]) == spec.artifact)
      )
  end

  @doc "Resolve the worker-local artifact path for a specification already accepted by `supports?/2`."
  @spec artifact_path(t(), ExecutionSpec.t()) :: String.t()
  def artifact_path(worker, %{artifact: %{"kind" => "checkpoint"}} = spec),
    do: approved_checkpoint(worker, spec).path

  def artifact_path(worker, spec) do
    Enum.find(
      worker.artifacts,
      &(Map.take(&1, ["id", "sha256", "architecture"]) == spec.artifact)
    )["path"]
  end

  @doc false
  def machine_spec(worker, %{artifact: %{"kind" => "checkpoint"}} = spec, name),
    do: Checkpoint.machine(approved_checkpoint(worker, spec), name)

  def machine_spec(worker, spec, name),
    do: Profile.machine(spec.profile, name, artifact_path(worker, spec))

  defp approved_checkpoint(worker, spec),
    do: Enum.find(worker.checkpoints, &(Checkpoint.artifact(&1) == spec.artifact))

  defp checkpoints?(worker) do
    Validation.list?(worker.checkpoints, 32) and
      Enum.all?(worker.checkpoints, fn checkpoint ->
        Checkpoint.validate(checkpoint) == :ok and
          checkpoint.platform == worker.platform and
          checkpoint.architecture == worker.architecture and
          checkpoint.runtime_version == worker.runtime_version and
          checkpoint.profile in worker.profiles
      end) and unique?(worker.checkpoints, & &1.id)
  end

  defp valid_fields?(worker) do
    valid_client?(worker.client) and supported_runtime?(worker) and
      worker.qualification == :development and valid_platform?(worker) and
      is_boolean(worker.draining) and capacity?(worker.capacity) and catalogs?(worker) and
      allocation_floor?(worker.allocation_floor)
  end

  defp supported_runtime?(%{runtime_version: "1.14.1"}), do: true

  defp supported_runtime?(%{runtime_version: version, platform: platform, architecture: arch})
       when version in ["1.14.6", "1.16.0", "1.16.1"],
       do: {platform, arch} in [{:linux, "x86_64"}, {:macos, "aarch64"}]

  defp supported_runtime?(_worker), do: false

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
      (worker.artifacts != [] or worker.checkpoints != []) and checkpoints?(worker) and
      Enum.all?(worker.artifacts, &artifact?(&1, worker.architecture)) and
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

  defp allocation_floor?(
         %{storage_gb: storage, overlay_gb: overlay, host_overhead_mb: memory} = floor
       ),
       do:
         map_size(floor) == 3 and Validation.integer?(storage, 1, 64) and
           Validation.integer?(overlay, 1, 64) and Validation.integer?(memory, 128, 16_384)

  defp allocation_floor?(_floor), do: false

  defp allocation_fits?(worker, profile),
    do:
      Enum.all?(worker.allocation_floor, fn {field, minimum} ->
        Map.fetch!(profile, field) >= minimum
      end)

  defp unique?(entries, function),
    do: MapSet.size(MapSet.new(entries, function)) == length(entries)

  defp invalid, do: {:error, %Error{category: :validation, operation: :runtime}}
end
