defmodule SmolBox.Profile do
  @moduledoc """
  Immutable, host-selected policy for disposable offline executions.

  `id` identifies this exact policy revision. CPU and memory are guest allocations;
  disk sizes are requested guest volumes, not worker filesystem quotas. The
  worker's required `allocation_floor` must cover its actual disk templates;
  upstream reports requests even when a larger template is retained. Host admission also
  reserves `host_overhead_mb`. No CPU-time, host RSS, process-count, or host-disk
  hard quota is promised. Requests for such controls are rejected as unsupported.
  Worker qualification and host isolation remain prerequisites for managed use.

  Budgets cover preparation, command observation, collection, and cleanup
  separately. A socket timeout is never evidence of guest termination.
  """

  alias SmolBox.{Error, MachineSpec, Validation}

  @schema [
    cpus: [type: :pos_integer, default: 1],
    memory_mb: [type: :pos_integer, default: 256],
    storage_gb: [type: :pos_integer, default: 1],
    overlay_gb: [type: :pos_integer, default: 1],
    host_overhead_mb: [type: :pos_integer, default: 256],
    max_output_bytes: [type: :pos_integer, default: 1_048_576],
    max_file_bytes: [type: :pos_integer, default: 1_048_576],
    max_total_file_bytes: [type: :pos_integer, default: 4_194_304],
    preparation_ms: [type: :pos_integer, default: 60_000],
    execution_ms: [type: :pos_integer, default: 30_000],
    collection_ms: [type: :pos_integer, default: 30_000],
    cleanup_ms: [type: :pos_integer, default: 30_000]
  ]
  @defaults Enum.map(@schema, fn {key, schema} -> {key, schema[:default]} end)
  @unsupported [
    :network,
    :mounts,
    :ports,
    :gpu,
    :cpu_time_ms,
    :host_rss_mb,
    :process_limit,
    :host_disk_bytes,
    :restart,
    :background
  ]
  @enforce_keys [:id]
  defstruct [:id] ++ @defaults

  @type t :: %__MODULE__{
          id: String.t(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer(),
          host_overhead_mb: pos_integer(),
          max_output_bytes: pos_integer(),
          max_file_bytes: pos_integer(),
          max_total_file_bytes: pos_integer(),
          preparation_ms: pos_integer(),
          execution_ms: pos_integer(),
          collection_ms: pos_integer(),
          cleanup_ms: pos_integer()
        }

  @doc """
  Create an immutable host-approved profile revision.

  | Option | Default | Range/meaning |
  |---|---|---|
  | `:cpus` | `1` | 1–64 guest vCPUs |
  | `:memory_mb` | `256` | 128–16,384 MiB guest allocation |
  | `:storage_gb` | `1` | 1–64 GiB storage allocation |
  | `:overlay_gb` | `1` | 1–64 GiB overlay allocation |
  | `:host_overhead_mb` | `256` | 128–16,384 MiB additional admission reservation |
  | `:max_output_bytes` | `1_048_576` | 1 byte–8 MiB of combined captured stdout/stderr |
  | `:max_file_bytes` | `1_048_576` | 1 byte–1 MiB per declared file |
  | `:max_total_file_bytes` | `4_194_304` | 1 byte–16 MiB per direction; must cover `:max_file_bytes` |
  | `:preparation_ms` | `60_000` | First preparation stage budget |
  | `:execution_ms` | `30_000` | Command observation budget |
  | `:collection_ms` | `30_000` | Output collection budget |
  | `:cleanup_ms` | `30_000` | Cleanup mutation budget, separate from unknown-outcome retention |

  Each stage budget must be 1000–300,000 ms. A default profile is structurally
  valid but its 1/1 GiB disks do **not** meet the reference SmolVM 1.14.1 template
  floor. Use the actual operator-verified floor, as in the example below.

  Give every changed policy a new `id`; managed submission matches the complete
  profile against the worker's catalog. Unsupported hard quotas and networking,
  mounts, ports, GPU, restart or background options return `:unsupported_capability`.

  ## Example

      iex> {:ok, profile} = SmolBox.Profile.new("offline-v1", storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768)
      iex> {profile.storage_gb, profile.overlay_gb, profile.max_output_bytes}
      {20, 10, 1_048_576}
  """
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, options \\ []) do
    with :ok <- supported(options),
         {:ok, options} <- NimbleOptions.validate(options, @schema),
         profile = struct!(__MODULE__, [{:id, id} | options]),
         :ok <- validate(profile) do
      {:ok, profile}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  @doc "Revalidate profile shape and bounds; this does not attest worker enforcement."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = profile) do
    if Validation.struct_shape?(profile, __MODULE__),
      do: validate_fields(profile),
      else: invalid()
  end

  def validate(_profile), do: invalid()

  @doc "Convert only the supported machine allocation controls."
  @spec machine(t(), String.t(), String.t()) :: {:ok, MachineSpec.t()} | {:error, Error.t()}
  def machine(profile, name, artifact_path) do
    with :ok <- validate(profile) do
      options =
        profile |> Map.from_struct() |> Map.take([:cpus, :memory_mb, :storage_gb, :overlay_gb])

      MachineSpec.new(name, artifact_path, Map.to_list(options))
    end
  end

  defp validate_fields(profile) do
    checks = [
      Validation.identifier?(profile.id),
      Validation.integer?(profile.cpus, 1, 64),
      Validation.integer?(profile.memory_mb, 128, 16_384),
      Validation.integer?(profile.storage_gb, 1, 64),
      Validation.integer?(profile.overlay_gb, 1, 64),
      Validation.integer?(profile.host_overhead_mb, 128, 16_384),
      Validation.integer?(profile.max_output_bytes, 1, 8_388_608),
      Validation.integer?(profile.max_file_bytes, 1, 1_048_576),
      Validation.integer?(profile.max_total_file_bytes, 1, 16_777_216),
      profile.max_file_bytes <= profile.max_total_file_bytes,
      budgets?(profile)
    ]

    if Enum.all?(checks), do: :ok, else: invalid()
  end

  defp budgets?(profile) do
    Enum.all?(
      [profile.preparation_ms, profile.execution_ms, profile.collection_ms, profile.cleanup_ms],
      &Validation.integer?(&1, 1000, 300_000)
    )
  end

  defp supported(options) do
    cond do
      not Keyword.keyword?(options) ->
        invalid()

      Enum.any?(Keyword.keys(options), &(&1 in @unsupported)) ->
        {:error, %Error{category: :unsupported_capability, operation: :profile}}

      true ->
        :ok
    end
  end

  defp invalid, do: {:error, %Error{category: :validation, operation: :profile}}
end
