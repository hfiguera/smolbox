defmodule SmolBox.Embedded.Config do
  @moduledoc """
  Explicit approvals for an owner-bound embedded target using the Port bridge.

  Construction validates values without reading files, enrolling a domain,
  launching a helper, or probing a hypervisor. Runtime startup must separately
  verify the package and approve its exact handshake before admitting work.
  Pass the validated configuration in `SmolBox.child_spec/1`'s `:workers` option
  to start the Port backend. This constructor alone starts no helper.
  A runtime supports one embedded domain per BEAM node alongside HTTP workers;
  startup requires store backend-binding, recovery and managed-machine support.

  Required options are `:id`, `:package_path`, `:package_identity`,
  `:package_manifest_sha256`, `:domain_generation`, `:platform`, `:architecture`,
  `:artifacts`, `:profiles`, `:capacity`, and `:allocation_floor`. `package_path`
  names the absolute native package directory containing `smolbox-port` and
  `package.json`. `package_identity` has exactly the string keys `engine_version`,
  `smolvm_revision`, `source_sha256`, `build_sha256`, `assets_sha256`, `platform`,
  and `architecture`, matching the locally approved package.

  Artifact entries have exactly the string keys `id`, `sha256`, `architecture`,
  `path`, and `max_bytes`. Approvals cover an absolute prepared `.smolmachine`
  file and a 1-byte–32-GiB verification bound. Profiles must be offline, fit the
  declared allocation floor, and remain within the native resource/time limits.
  Capacity and allocation floor use the same declarations as
  `SmolBox.Runtime.WorkerConfig`; they are not measurements or host quotas.

  `domain_generation` is the previously enrolled 32-character lowercase hex
  generation for this stable target ID. The first native implementation uses
  verified smolvm default paths under one dedicated OS account. It does not
  accept arbitrary database paths. `allow_initialize: true` explicitly authorizes
  initial enrollment with the supplied generation; it never replaces an existing
  descriptor. This option defaults to false. A store must fence domain changes
  while assignments or reservations exist.

  Optional `:bridge` defaults to `:port`. `:draining` defaults to false,
  `:limits` defaults to `SmolBox.Embedded.Limits`, and `:budget` defaults to a
  24-hour operation budget with 1-MiB request frames and 16-MiB response allowance.
  Profile and remaining operation budgets further constrain individual requests.

  The deprecated `:qualification` option accepts `:development` for compatibility.
  Omit it in new configurations. Use [Validated configurations](supported-platforms.html#validated-configurations)
  to assess deployment support.

  Optional source/checkpoint/export/branch/volume catalogs and registry credential
  resolution use the shared HTTP approval rules. `:registry_policy` supplies explicit host
  download/cache limits and approved token realms through
  `SmolBox.Embedded.RegistryPolicy`; token values stay in the credential resolver.
  A registry catalog selected by remote_sources requires this policy. Dormant
  legacy catalogs remain valid without it. Catalog approval does not enable
  an operation absent from the approved helper. Legacy helpers still accept only
  local offline assignments. OCI and registry catalogs without a local artifact
  require the remote_sources descriptor. Checkpoint-only catalogs require the
  checkpoints descriptor. The Linux source policy enables remote sources and
  images for newly rebuilt, exactly approved packages; older packages retain
  their original surface. Ordinary public qualification remains package-specific.
  `sdk_version/1` describes the pinned SDK independently of the SmolBox engine version.

  Engine `0.2.0` packages use protocol 2 and manifest schema 3. Package policy and
  Hello must agree on the exact implemented SDK feature descriptor. The store
  additionally needs `native_material_proofs: 2`, including the selective v17
  reader, before enrollment. Upgrade every durable reader first. Legacy `0.1.0`
  packages keep protocol 1.3/1.4 and v16 authority; their receipts are never promoted.
  A descriptor with `background_exec: 1` additionally requires store capability
  `native_background_launches: 1`; material-reader support alone is insufficient.
  A descriptor with `terminals: 1` additionally requires
  `native_terminal_sessions: 1` after upgrading every native v17 terminal reader
  and command-slot transaction. Ordinary guest/platform qualification remains separate.

  Optional `:sdk_identity` approves an explicit protocol-2 SDK descriptor from the
  trusted manifest policy. Omission selects this library's current implemented
  descriptor. Explicit approval can retain an older, smaller protocol-2 feature
  set; unknown or unimplemented features and missing core features reject before
  startup. The manifest and Hello must match that exact descriptor and its limits.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.{Limits, RegistryPolicy, SDKIdentity}
  alias SmolBox.{Error, Profile, Validation}
  alias SmolBox.Runtime.Approvals

  @legacy_revision "9f446ae00219148ca4a703914f44a8e2fab11655"
  @sdk_versions %{
    @legacy_revision => "1.22.0",
    "d77eaf1c6eeff16bc8c258613746033e9bf567ca" => "1.34.0"
  }
  @package_keys ~w(engine_version smolvm_revision source_sha256 build_sha256 assets_sha256 platform architecture)
  @artifact_keys ~w(id sha256 architecture path max_bytes)
  @required [
    :id,
    :package_path,
    :package_identity,
    :package_manifest_sha256,
    :domain_generation,
    :platform,
    :architecture,
    :artifacts,
    :profiles,
    :capacity,
    :allocation_floor
  ]
  @optional [
    :bridge,
    :qualification,
    :draining,
    :allow_initialize,
    :limits,
    :budget,
    :sources,
    :checkpoints,
    :export_destinations,
    :checkpoint_policies,
    :branch_policies,
    :volume_policy,
    :registry_credentials,
    :registry_policy,
    :sdk_identity,
    :publish_address
  ]
  @enforce_keys @required
  @derive {Inspect, only: [:id, :bridge, :platform, :architecture, :draining]}
  defstruct @required ++
              [
                bridge: :port,
                qualification: :development,
                draining: false,
                allow_initialize: false,
                sources: [],
                checkpoints: [],
                export_destinations: [],
                checkpoint_policies: [],
                branch_policies: [],
                volume_policy: nil,
                registry_credentials: nil,
                registry_policy: nil,
                sdk_identity: nil,
                publish_address: "127.0.0.1",
                limits: %Limits{},
                budget: %Budget{
                  timeout_ms: 86_400_000,
                  max_request_bytes: 1_048_576,
                  max_response_bytes: 16_777_216
                }
              ]

  @type t :: %__MODULE__{
          id: String.t(),
          bridge: :port,
          package_path: String.t(),
          package_identity: %{String.t() => String.t()},
          package_manifest_sha256: String.t(),
          domain_generation: String.t(),
          allow_initialize: boolean(),
          platform: :linux | :macos,
          architecture: String.t(),
          artifacts: [map()],
          profiles: [Profile.t()],
          sources: [SmolBox.Source.t()],
          checkpoints: [SmolBox.Checkpoint.t()],
          export_destinations: [SmolBox.ExportDestination.t()],
          checkpoint_policies: [SmolBox.CheckpointPolicy.t()],
          branch_policies: [SmolBox.BranchPolicy.t()],
          volume_policy: SmolBox.VolumePolicy.t() | nil,
          registry_credentials: {module(), term()} | nil,
          registry_policy: SmolBox.Embedded.RegistryPolicy.t() | nil,
          sdk_identity: map() | nil,
          publish_address: String.t(),
          capacity: SmolBox.Store.capacity(),
          allocation_floor: map(),
          qualification: :development,
          draining: boolean(),
          limits: Limits.t(),
          budget: Budget.t()
        }

  @doc "Validate embedded approvals without contacting the native package or data domain."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options), do: Validation.construct(__MODULE__, options, @required, @optional)

  @doc "Revalidate exact configuration shape and approvals without side effects."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = config) do
    cond do
      not Validation.struct_shape?(config, __MODULE__) -> invalid()
      config.bridge == :rustler -> unsupported()
      valid_fields?(config) -> :ok
      true -> invalid()
    end
  end

  def validate(_config), do: invalid()

  @doc false
  def domain_binding(%__MODULE__{} = config),
    do: %{kind: :embedded, target_id: config.id, generation: config.domain_generation}

  @doc false
  def executable(%__MODULE__{} = config), do: Path.join(config.package_path, "smolbox-port")

  @doc "Return the SDK version bound to the source revision, independently of the engine."
  def sdk_version(%__MODULE__{package_identity: %{"smolvm_revision" => revision}}),
    do: Map.get(@sdk_versions, revision)

  def sdk_version(_unrecognized), do: nil

  @doc false
  def protocol_major(%__MODULE__{package_identity: %{"engine_version" => "0.1.0"}}), do: 1
  def protocol_major(%__MODULE__{package_identity: %{"engine_version" => "0.2.0"}}), do: 2
  def protocol_major(_unrecognized), do: nil

  @doc false
  def sdk_identity(%__MODULE__{} = config) do
    if protocol_major(config) == 2,
      do:
        config.sdk_identity ||
          SDKIdentity.implemented(sdk_version(config), config.package_identity["smolvm_revision"]),
      else: nil
  end

  defp valid_fields?(config) do
    identity?(config) and launch_approval?(config) and
      operator_policy?(config) and catalogs?(config) and
      optional_catalogs?(config) and
      capacity?(config.capacity) and
      allocation_floor?(config.allocation_floor) and Limits.validate(config.limits) == :ok and
      budget?(config.budget)
  end

  defp launch_approval?(config),
    do: sdk_approval?(config) and publish_address?(config.publish_address)

  defp sdk_approval?(config) do
    case protocol_major(config) do
      1 ->
        config.sdk_identity == nil

      2 ->
        SDKIdentity.approved?(
          sdk_identity(config),
          sdk_version(config),
          config.package_identity["smolvm_revision"],
          config.platform
        )

      _ ->
        false
    end
  end

  defp identity?(config) do
    native_id?(config.id) and absolute_path?(config.package_path) and config.package_path != "/" and
      hex?(config.domain_generation, 32) and Validation.digest?(config.package_manifest_sha256) and
      {config.platform, config.architecture} in [
        {:linux, "x86_64"},
        {:linux, "aarch64"},
        {:macos, "aarch64"}
      ] and
      package?(config)
  end

  defp operator_policy?(config),
    do:
      config.bridge == :port and config.qualification == :development and
        is_boolean(config.draining) and is_boolean(config.allow_initialize)

  defp package?(%{package_identity: package} = config) do
    exact_keys?(package, @package_keys) and supported_sdk?(protocol_major(config), package) and
      package["platform"] == Atom.to_string(config.platform) and
      package["architecture"] == config.architecture and
      Enum.all?(~w(source_sha256 build_sha256 assets_sha256), &Validation.digest?(package[&1]))
  end

  defp supported_sdk?(1, package), do: package["smolvm_revision"] == @legacy_revision
  defp supported_sdk?(2, package), do: Map.has_key?(@sdk_versions, package["smolvm_revision"])
  defp supported_sdk?(_protocol, _package), do: false

  defp catalogs?(config) do
    Validation.list?(config.artifacts, 32) and catalog_present?(config) and
      Enum.all?(config.artifacts, &artifact?(&1, config.architecture)) and
      unique?(config.artifacts, & &1["id"]) and unique?(config.artifacts, & &1["path"]) and
      Validation.list?(config.profiles, 32) and config.profiles != [] and
      Enum.all?(config.profiles, &profile?(&1, config)) and
      unique?(config.profiles, & &1.id)
  end

  defp catalog_present?(config),
    do: config.artifacts != [] or source_only?(config) or checkpoint_only?(config)

  defp checkpoint_only?(config),
    do:
      config.checkpoints != [] and
        match?(%{"feature_versions" => %{"checkpoints" => 1}}, sdk_identity(config))

  defp source_only?(config),
    do:
      match?(%{"feature_versions" => %{"remote_sources" => 1}}, sdk_identity(config)) and
        config.sources != [] and
        Enum.all?(
          config.sources,
          &match?(%SmolBox.Source{kind: kind} when kind in [:oci, :registry], &1)
        )

  defp artifact?(artifact, architecture) do
    exact_keys?(artifact, @artifact_keys) and Validation.identifier?(artifact["id"]) and
      Validation.digest?(artifact["sha256"]) and artifact["architecture"] == architecture and
      absolute_path?(artifact["path"]) and String.ends_with?(artifact["path"], ".smolmachine") and
      Validation.integer?(artifact["max_bytes"], 1, 34_359_738_368)
  end

  defp profile?(profile, config) do
    floor = config.allocation_floor

    Profile.validate(profile) == :ok and
      (profile.network == :offline or network_approved?(config)) and profile.cpus <= 16 and
      profile.max_output_bytes <= 16_777_216 and profile.max_file_bytes <= 16_777_216 and
      profile.execution_ms <= 86_400_000 and allocation_floor?(floor) and
      Enum.all?(floor, fn {field, minimum} -> Map.fetch!(profile, field) >= minimum end)
  end

  defp network_approved?(config) do
    case sdk_identity(config) do
      %{"feature_versions" => %{"networking" => 1}} -> true
      _legacy -> false
    end
  end

  defp publish_address?(value) when is_binary(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, address} when tuple_size(address) == 4 -> to_string(:inet.ntoa(address)) == value
      _invalid -> false
    end
  end

  defp publish_address?(_value), do: false

  defp optional_catalogs?(config) do
    version = sdk_version(config)

    Approvals.sources?(config.sources, version, config.architecture) and
      Approvals.checkpoints?(
        config.checkpoints,
        version,
        config.platform,
        config.architecture,
        config.profiles
      ) and
      Approvals.export_destinations?(config.export_destinations, version) and
      Approvals.checkpoint_policies?(config.checkpoint_policies, version) and
      Approvals.branch_policies?(config.branch_policies, version) and
      Approvals.volume_policy?(config.volume_policy, version, config.platform) and
      SmolBox.RegistryCredentials.valid?(config.registry_credentials) and
      registry_policy?(config)
  end

  defp registry_policy?(config) do
    valid = RegistryPolicy.catalog?(config.registry_policy, config.sources)

    required =
      match?(%{"feature_versions" => %{"remote_sources" => 1}}, sdk_identity(config)) and
        Enum.any?(config.sources, &(&1.kind == :registry))

    valid and (not required or config.registry_policy != nil)
  end

  defp capacity?(capacity), do: Approvals.capacity?(capacity)

  defp allocation_floor?(floor), do: Approvals.allocation_floor?(floor)

  defp budget?(budget),
    do:
      Budget.valid?(budget) and budget.timeout_ms <= 86_400_000 and
        budget.max_request_bytes <= 1_048_576 and budget.max_response_bytes <= 16_777_216

  defp exact_keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp unique?(entries, key), do: MapSet.size(MapSet.new(entries, key)) == length(entries)

  defp native_id?(value),
    do:
      Validation.identifier?(value) and
        Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value)

  defp hex?(value, length),
    do:
      is_binary(value) and byte_size(value) == length and
        Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp absolute_path?(value),
    do:
      Validation.text?(value, 4096) and String.starts_with?(value, "/") and
        not Enum.member?(String.split(value, "/"), "..")

  defp invalid, do: {:error, %Error{category: :validation, operation: :embedded}}
  defp unsupported, do: {:error, %Error{category: :unsupported_capability, operation: :embedded}}
end
