defmodule SmolBox.Runtime.WorkerConfig do
  @moduledoc """
  Host-approved managed worker, prepared artifacts, and exact profile revisions.

  Optional `:sources` registers up to 32 exact remote `SmolBox.Source` approvals
  on smolvm 1.19.0, 1.20.2, 1.22.0 or 1.34.0. Each must match this worker's guest architecture. An OCI
  source also requires an explicit network profile. Registry artifacts download
  on the worker host, independently of guest networking. Approving a source
  authorizes that exact registry/repository/manifest/content identity, not an
  arbitrary tag or registry-wide catalog. Use one worker identity and store
  authority for each physical artifact cache; external mutations are outside
  the store's preparation exclusion.

  Optional `:registry_credentials` is `{resolver_module, host_context}`; see
  `SmolBox.RegistryCredentials`. Only safe references appear in stored sources.

  Optional `:branch_https_credentials` is a host resolver for held branches on
  SmolVM 1.34.0 over HTTPS or a local Unix socket. See
  `SmolBox.BranchHTTPSCredentials`.

  On 1.22.0, eligible OCI creation can use a shared image seed and temporary
  network-enabled builder. Budget that preparation and retained host cache
  separately; machine reservations and guest egress rules do not bound them.
  Operators can disable it with `SMOLVM_IMAGE_SEEDS=0` on the worker.

  Optional `:checkpoint_policies` approves exact `SmolBox.CheckpointPolicy` values
  for private controller storage and additional capture resources on 1.19.0, 1.20.2, 1.22.0 or 1.34.0.
  See `SmolBox.Checkpoints` for idle assertions, quiescence and artifact retention.

  Optional `:branch_policies` approves exact `SmolBox.BranchPolicy` values for
  same-worker leaf branches on 1.19.0, 1.20.2, 1.22.0 or 1.34.0. Extra backing allowances survive child
  deletion and dependency retirement; see `SmolBox.Branches` for cleanup.

  Optional `:export_destinations` approves exact `SmolBox.ExportDestination`
  values for stopped-machine publication on 1.19.0, 1.20.2, 1.22.0 or 1.34.0. Each includes additional
  helper resources, immutable tag policy, and a credential reference resolving
  a scoped publication bearer. A successful response does not attest helper
  cleanup; see `SmolBox.Exports` for explicit quiescence confirmation.

  Artifact entries have `id`, `sha256`, `architecture`, and an absolute prepared
  `.smolmachine` `path` on this worker. The operator verifies artifact digests,
  approved startup behavior, disabled automatic workload restart, and the pinned runtime
  before registering them. Managed admission compares the server-reported version
  and checks readiness; the worker API cannot attest artifact contents or isolation.

  `checkpoints` optionally registers `SmolBox.Checkpoint` approvals. Each binds
  an idle offline source to its exact profile, platform, architecture and declared
  runtime. `artifacts: []` is accepted when checkpoints are configured. Approval
  is supplied by the operator and is not remotely attested.

  `allocation_floor` is a required operator declaration with `storage_gb`,
  `overlay_gb`, and `host_overhead_mb`. It must cover the largest actual disk
  templates across this worker's runtime and approved artifacts, and its VMM
  overhead. smolvm 1.14.1 only grows disk templates: a smaller API request can
  still expose a larger guest disk. Admission rejects profiles below these
  floors. This declaration is not remotely attested or a host filesystem quota.

  Versions 1.14.6, 1.16.0, 1.16.1, 1.17.0, 1.19.0, 1.20.2, 1.22.0 and 1.34.0 require working host `resize2fs` for disk requests below
  template sizes. Verify file persistence across stop/start before admission;
  see [Supported platforms](supported-platforms.html#host-prerequisites).

  Enforce host resource limits separately from worker admission. `SmolBox.Profile`
  rejects unsupported hard controls. Verify worker readiness and approved
  artifacts before admitting work.
  """
  alias SmolBox.Backend.Features
  alias SmolBox.ExecutionFeatures
  alias SmolBox.Runtime.Approvals

  alias SmolBox.{
    BranchHTTPSCredentials,
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
  @derive {Inspect, only: [:architecture, :platform, :runtime_version]}
  defstruct @enforce_keys ++
              [
                runtime_version: "1.34.0",
                qualification: :development,
                draining: false,
                checkpoints: [],
                sources: [],
                export_destinations: [],
                checkpoint_policies: [],
                branch_policies: [],
                volume_policy: nil,
                registry_credentials: nil,
                branch_https_credentials: nil
              ]

  @type t :: %__MODULE__{
          volume_policy: SmolBox.VolumePolicy.t() | nil,
          client: Client.t(),
          architecture: String.t(),
          platform: :linux | :macos,
          artifacts: [map()],
          checkpoints: [Checkpoint.t()],
          sources: [SmolBox.Source.t()],
          registry_credentials: {module(), term()} | nil,
          branch_https_credentials: {module(), term()} | nil,
          export_destinations: [SmolBox.ExportDestination.t()],
          checkpoint_policies: [SmolBox.CheckpointPolicy.t()],
          branch_policies: [SmolBox.BranchPolicy.t()],
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
  `SmolBox.Checkpoint` approvals. At least one local image, checkpoint, or remote
  source is required. `:sources` defaults to `[]`; `:registry_credentials` to nil.

  Other optional fields are `:runtime_version` (default `"1.34.0"` for Linux x86_64 or
  macOS Apple Silicon; explicitly select `"1.22.0"`, `"1.20.2"`, `"1.19.0"`, `"1.17.0"`, `"1.16.1"`, `"1.16.0"`, `"1.14.1"` or `"1.14.6"`
  for another supported worker) and `:draining` (default `false`). Artifact IDs must
  be unique and architectures must match this worker. Construction makes no worker
  request or remote digest check. Profiles below the floor cannot support execution.
  Set `:runtime_version` to the version installed on the worker; the library does
  not install or upgrade it. Explicit `"1.34.0"` selection is available for HTTP
  worker qualification. See [Supported platforms](supported-platforms.html)
  for host prerequisites and feature limits, and
  [Upgrading SmolBox](https://github.com/hfiguera/smolbox/blob/v0.5.1/docs/upgrading.md)
  before changing an existing deployment.
  See [Getting started](getting-started.html) for a complete configuration.

  The deprecated `:qualification` option accepts `:development` for compatibility.
  Omit it in new configurations. Use [Validated configurations](supported-platforms.html#validated-configurations)
  to assess deployment support.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(
         options,
         @enforce_keys ++
           [
             :runtime_version,
             :qualification,
             :draining,
             :checkpoints,
             :sources,
             :registry_credentials,
             :branch_https_credentials,
             :export_destinations,
             :checkpoint_policies,
             :branch_policies,
             :volume_policy
           ]
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
  @spec supports?(t(), ExecutionSpec.t() | SmolBox.ManagedMachineSpec.t()) :: boolean()
  def supports?(%{runtime_version: version}, %{checkpointable: true})
      when version not in ["1.19.0", "1.20.2", "1.22.0", "1.34.0"],
      do: false

  def supports?(worker, %{artifact: %{"kind" => "checkpoint"}} = spec) do
    ExecutionFeatures.worker_supported?(worker, spec) and
      not SmolBox.FileAccess.extended?(spec.profile) and
      Map.get(spec, :ports, []) == [] and
      Map.get(spec, :workload) == nil and
      approved_profile?(worker, spec.profile) and
      Enum.any?(worker.checkpoints, fn checkpoint ->
        Checkpoint.artifact(checkpoint) == spec.artifact and checkpoint.profile == spec.profile
      end)
  end

  def supports?(worker, spec) do
    ExecutionFeatures.worker_supported?(worker, spec) and
      extensions_supported?(worker, spec) and
      file_support?(worker, spec) and
      workload_supported?(worker, spec) and
      network_supported?(worker, spec) and
      approved_profile?(worker, spec.profile) and
      worker.architecture == spec.artifact["architecture"] and
      approved_artifact?(worker, spec)
  end

  defp extensions_supported?(worker, spec),
    do:
      pull_supported?(worker, spec) and volume_supported?(worker, spec) and
        ports_supported?(worker, spec)

  defp pull_supported?(worker, %{command: %SmolBox.ImagePull{source: source}} = spec),
    do:
      spec.artifact["kind"] == "oci" and Features.supports?(worker, :images) and
        source in worker.sources and
        source.architecture == worker.architecture

  defp pull_supported?(_worker, _spec), do: true

  defp approved_profile?(worker, profile),
    do: profile in worker.profiles and allocation_fits?(worker, profile)

  @doc "Resolve the worker-local artifact path for a specification already accepted by `supports?/2`."
  @spec artifact_path(t(), ExecutionSpec.t() | SmolBox.ManagedMachineSpec.t()) :: String.t() | nil
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

  def machine_spec(worker, spec, name) do
    source =
      if SmolBox.Source.remote?(spec.artifact),
        do: Enum.find(worker.sources, &(SmolBox.Source.artifact(&1) == spec.artifact)),
        else: artifact_path(worker, spec)

    with {:ok, machine} <- Profile.machine(spec.profile, name, source) do
      machine = %{machine | ports: Map.get(spec, :ports, []), workload: Map.get(spec, :workload)}
      with :ok <- MachineSpec.validate(machine), do: {:ok, machine}
    end
  end

  defp approved_artifact?(worker, spec) do
    if SmolBox.Source.remote?(spec.artifact) do
      Features.supports?(worker, :remote_sources) and
        (spec.artifact["kind"] != "oci" or spec.profile.network != :offline) and
        Enum.any?(worker.sources, &(SmolBox.Source.artifact(&1) == spec.artifact))
    else
      Enum.any?(
        worker.artifacts,
        &(Map.take(&1, ["id", "sha256", "architecture"]) == spec.artifact)
      )
    end
  end

  defp network_supported?(worker, %{branch_static_egress: true}),
    do:
      worker.platform == :linux and worker.architecture == "x86_64" and
        worker.runtime_version == "1.34.0"

  defp network_supported?(worker, spec),
    do:
      spec.profile.network == :offline or
        (Features.supports?(worker, :networking) and
           (not Map.get(spec, :checkpointable, false) or https_branches?(worker, spec.profile)))

  @doc false
  def https_branches?(worker, profile),
    do:
      worker.branch_https_credentials != nil and
        https_resolver?(worker) and BranchHTTPSCredentials.network?(profile.network)

  defp https_resolver?(worker),
    do:
      BranchHTTPSCredentials.configured?(
        worker.branch_https_credentials,
        worker.client.worker,
        worker.runtime_version
      )

  defp file_support?(worker, spec),
    do:
      SmolBox.FileAccess.supports?(worker.client, spec.profile) and
        (not SmolBox.FileAccess.extended?(spec.profile) or
           Features.supports?(worker, :extended_files))

  defp workload_supported?(worker, spec),
    do: Map.get(spec, :workload) == nil or Features.supports?(worker, :workloads)

  defp volume_supported?(worker, spec),
    do:
      Map.get(spec, :volumes, []) == [] or
        (worker.volume_policy != nil and Features.supports?(worker, :volumes))

  defp volume_policy?(worker),
    do: Approvals.volume_policy?(worker.volume_policy, worker.runtime_version, worker.platform)

  defp ports_supported?(worker, spec),
    do:
      Map.get(spec, :ports, []) == [] or
        Features.supports?(worker, :ports)

  defp approved_checkpoint(worker, spec),
    do: Enum.find(worker.checkpoints, &(Checkpoint.artifact(&1) == spec.artifact))

  defp checkpoints?(worker),
    do:
      Approvals.checkpoints?(
        worker.checkpoints,
        worker.runtime_version,
        worker.platform,
        worker.architecture,
        worker.profiles
      )

  defp valid_fields?(worker) do
    valid_client?(worker.client) and supported_runtime?(worker) and
      worker.qualification == :development and valid_platform?(worker) and
      is_boolean(worker.draining) and capacity?(worker.capacity) and catalogs?(worker) and
      allocation_floor?(worker.allocation_floor) and operator_policies?(worker)
  end

  defp supported_runtime?(%{runtime_version: "1.14.1"}), do: true

  defp supported_runtime?(%{runtime_version: version, platform: platform, architecture: arch})
       when version in [
              "1.14.6",
              "1.16.0",
              "1.16.1",
              "1.17.0",
              "1.19.0",
              "1.20.2",
              "1.22.0",
              "1.34.0"
            ],
       do: {platform, arch} in [{:linux, "x86_64"}, {:macos, "aarch64"}]

  defp supported_runtime?(_worker), do: false

  defp valid_client?(%Client{} = client) do
    Validation.struct_shape?(client, Client) and
      match?(
        {:ok, _client},
        Client.new(client.worker,
          transport: client.transport,
          guest_paths: client.guest_paths,
          max_file_bytes: client.max_file_bytes
        )
      )
  end

  defp valid_client?(_client), do: false

  defp valid_platform?(worker),
    do:
      worker.architecture in ["x86_64", "aarch64"] and worker.platform in [:linux, :macos] and
        (worker.platform != :macos or worker.architecture == "aarch64")

  defp catalogs?(worker) do
    profiles?(worker.profiles) and Validation.list?(worker.artifacts, 32) and
      (worker.artifacts != [] or worker.checkpoints != [] or worker.sources != []) and
      checkpoints?(worker) and
      Enum.all?(worker.artifacts, &artifact?(&1, worker.architecture)) and
      sources?(worker) and
      unique?(worker.artifacts, & &1["id"])
  end

  defp operator_policies?(worker),
    do:
      volume_policy?(worker) and
        exports?(worker) and capture_policies?(worker) and branch_policies?(worker) and
        SmolBox.RegistryCredentials.valid?(worker.registry_credentials) and
        https_resolver?(worker)

  defp branch_policies?(worker),
    do: Approvals.branch_policies?(worker.branch_policies, worker.runtime_version)

  defp capture_policies?(worker),
    do: Approvals.checkpoint_policies?(worker.checkpoint_policies, worker.runtime_version)

  defp exports?(worker),
    do: Approvals.export_destinations?(worker.export_destinations, worker.runtime_version)

  defp sources?(worker),
    do: Approvals.sources?(worker.sources, worker.runtime_version, worker.architecture)

  defp profiles?(profiles), do: Approvals.profiles?(profiles)

  defp artifact?(
         %{"id" => id, "sha256" => digest, "architecture" => arch, "path" => path} = artifact,
         arch
       ) do
    map_size(artifact) == 4 and Validation.identifier?(id) and Validation.digest?(digest) and
      match?({:ok, _machine}, MachineSpec.new("approved-artifact", path))
  end

  defp artifact?(_artifact, _architecture), do: false

  defp capacity?(capacity), do: Approvals.capacity?(capacity)

  defp allocation_floor?(floor), do: Approvals.allocation_floor?(floor)

  defp allocation_fits?(worker, profile),
    do: Approvals.allocation_fits?(worker.allocation_floor, profile)

  defp unique?(entries, function),
    do: Approvals.unique?(entries, function)

  defp invalid, do: {:error, %Error{category: :validation, operation: :runtime}}
end
