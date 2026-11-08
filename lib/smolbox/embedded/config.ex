defmodule SmolBox.Embedded.Config do
  @moduledoc """
  Explicit approvals for an owner-bound embedded target using the Port bridge.

  Construction validates values without reading files, enrolling a domain,
  launching a helper, or probing a hypervisor. Runtime startup must separately
  verify the package and approve its exact handshake before admitting work.
  Pass the validated configuration in `SmolBox.child_spec/1`'s `:workers` option
  to start the development Port backend. This constructor alone starts no helper.
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

  Optional `:bridge` defaults to `:port`; Rustler remains an additive future
  bridge. `:qualification` is `:development`, `:draining` defaults to false,
  `:limits` defaults to `SmolBox.Embedded.Limits`, and `:budget` defaults to a
  24-hour operation budget with 1-MiB request frames and 16-MiB response allowance.
  Profile and remaining operation budgets further constrain individual requests.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.Limits
  alias SmolBox.{Error, Profile, Validation}

  @revision "9f446ae00219148ca4a703914f44a8e2fab11655"
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
  @optional [:bridge, :qualification, :draining, :allow_initialize, :limits, :budget]
  @enforce_keys @required
  @derive {Inspect, only: [:id, :bridge, :platform, :architecture, :qualification, :draining]}
  defstruct @required ++
              [
                bridge: :port,
                qualification: :development,
                draining: false,
                allow_initialize: false,
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

  defp valid_fields?(config) do
    identity?(config) and operator_policy?(config) and catalogs?(config) and
      capacity?(config.capacity) and
      allocation_floor?(config.allocation_floor) and Limits.validate(config.limits) == :ok and
      budget?(config.budget)
  end

  defp identity?(config) do
    native_id?(config.id) and absolute_path?(config.package_path) and config.package_path != "/" and
      hex?(config.domain_generation, 32) and Validation.digest?(config.package_manifest_sha256) and
      {config.platform, config.architecture} in [{:linux, "x86_64"}, {:macos, "aarch64"}] and
      package?(config)
  end

  defp operator_policy?(config),
    do:
      config.bridge == :port and config.qualification == :development and
        is_boolean(config.draining) and is_boolean(config.allow_initialize)

  defp package?(%{package_identity: package} = config) do
    exact_keys?(package, @package_keys) and package["engine_version"] == "0.1.0" and
      package["smolvm_revision"] == @revision and
      package["platform"] == Atom.to_string(config.platform) and
      package["architecture"] == config.architecture and
      Enum.all?(~w(source_sha256 build_sha256 assets_sha256), &Validation.digest?(package[&1]))
  end

  defp catalogs?(config) do
    Validation.list?(config.artifacts, 32) and config.artifacts != [] and
      Enum.all?(config.artifacts, &artifact?(&1, config.architecture)) and
      unique?(config.artifacts, & &1["id"]) and unique?(config.artifacts, & &1["path"]) and
      Validation.list?(config.profiles, 32) and config.profiles != [] and
      Enum.all?(config.profiles, &profile?(&1, config.allocation_floor)) and
      unique?(config.profiles, & &1.id)
  end

  defp artifact?(artifact, architecture) do
    exact_keys?(artifact, @artifact_keys) and Validation.identifier?(artifact["id"]) and
      Validation.digest?(artifact["sha256"]) and artifact["architecture"] == architecture and
      absolute_path?(artifact["path"]) and String.ends_with?(artifact["path"], ".smolmachine") and
      Validation.integer?(artifact["max_bytes"], 1, 34_359_738_368)
  end

  defp profile?(profile, floor) do
    Profile.validate(profile) == :ok and profile.network == :offline and profile.cpus <= 16 and
      profile.max_output_bytes <= 16_777_216 and profile.max_file_bytes <= 16_777_216 and
      profile.execution_ms <= 86_400_000 and allocation_floor?(floor) and
      Enum.all?(floor, fn {field, minimum} -> Map.fetch!(profile, field) >= minimum end)
  end

  defp capacity?(capacity),
    do:
      exact_keys?(capacity, [:slots, :cpus, :memory_mb, :disk_gb]) and
        Enum.all?(Map.values(capacity), &Validation.integer?(&1, 1, 1_048_576))

  defp allocation_floor?(floor),
    do:
      exact_keys?(floor, [:storage_gb, :overlay_gb, :host_overhead_mb]) and
        Validation.integer?(floor.storage_gb, 1, 64) and
        Validation.integer?(floor.overlay_gb, 1, 64) and
        Validation.integer?(floor.host_overhead_mb, 128, 16_384)

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
