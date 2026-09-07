defmodule SmolBox.ExecutionSpec do
  @moduledoc """
  Immutable managed execution intent; host code supplies policy and artifact approval.

  The runtime artifact map contains exactly `id`, `sha256`, and `architecture`
  (`x86_64` or `aarch64`). It is resolved against host configuration, never fetched
  as a caller-provided image URL. The specification contains no endpoint overrides.

  Queue budgets are relative at construction; the store must persist an absolute
  deadline on first acceptance. Repeated submission never resets that deadline.
  `fingerprint/2` uses a stable host secret (at least 32 bytes) to prevent guessing
  low-entropy environment/stdin values from a public hash. Rotate this key only
  with an explicit stored-identity migration. Do not log or persist its bytes.

  The host store must protect command/environment/stdin contents at rest; inspection
  of this struct excludes them. Metadata is limited to 16 bounded scalar entries.
  """

  alias SmolBox.{Command, Error, Manifest, Profile, Validation}

  @enforce_keys [:scope, :id, :artifact, :command, :profile]
  @derive {Inspect, only: [:scope, :id]}
  defstruct [
    :scope,
    :id,
    :artifact,
    :command,
    :profile,
    inputs: [],
    outputs: [],
    queue_ms: 60_000,
    retention_ms: 86_400_000,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          scope: String.t(),
          id: String.t(),
          artifact: %{String.t() => String.t()},
          command: Command.t(),
          profile: Profile.t(),
          inputs: [Manifest.input()],
          outputs: [Manifest.output()],
          queue_ms: pos_integer(),
          retention_ms: pos_integer(),
          metadata: %{String.t() => String.t() | integer() | boolean() | nil}
        }

  @doc """
  Validate a complete managed execution specification without dispatching it.

  Required options are `:scope`, `:id`, `:command` (`SmolBox.Command`), `:profile`
  (`SmolBox.Profile`), and `:artifact`. Scope and ID are 1–128 ASCII letters,
  digits, dots, underscores, colons or hyphens, starting with a letter/digit.
  The artifact has exactly string keys `"id"`, `"sha256"`, and `"architecture"`;
  its approved worker path is resolved from `SmolBox.Runtime.WorkerConfig`.

  | Optional field | Default | Meaning |
  |---|---|---|
  | `:inputs` | `[]` | Up to 32 exact input declarations; see `SmolBox.Manifest` |
  | `:outputs` | `[]` | Up to 32 exact output declarations; see `SmolBox.Manifest` |
  | `:queue_ms` | `60_000` | 1–86,400,000 ms from first acceptance until queue expiry |
  | `:retention_ms` | `86_400_000` | 60,000–2,592,000,000 ms after the execution deadline for unknown-outcome retention |
  | `:metadata` | `%{}` | Up to 16 string identifier keys with string (up to 256 bytes), bounded integer, boolean or nil values |

  The command timeout in seconds must fit the profile's execution budget in
  milliseconds. Successful construction proves shape and bounds, not worker
  availability or artifact approval; `SmolBox.submit/2` checks configured support.
  All semantic fields participate in identity conflict detection.

  ## Example

      iex> {:ok, command} = SmolBox.Command.new(["python", "-c", "print(42)"])
      iex> {:ok, profile} = SmolBox.Profile.new("offline-v1", storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768)
      iex> artifact = %{"id" => "python-v1", "sha256" => SmolBox.Files.sha256("example image bytes"), "architecture" => "aarch64"}
      iex> {:ok, spec} = SmolBox.ExecutionSpec.new(scope: "demo", id: "request-1", command: command, profile: profile, artifact: artifact)
      iex> {spec.scope, spec.id, spec.queue_ms}
      {"demo", "request-1", 60_000}

  The digest above is only a constructor example. Actual execution requires the
  digest of an approved prepared image, as shown in [Getting started](getting-started.html).
  """
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    allowed = [
      :scope,
      :id,
      :artifact,
      :command,
      :profile,
      :inputs,
      :outputs,
      :queue_ms,
      :retention_ms,
      :metadata
    ]

    if Validation.keys?(options, allowed) and
         Enum.all?([:scope, :id, :artifact, :command, :profile], &Keyword.has_key?(options, &1)) do
      spec = struct!(__MODULE__, options)
      with :ok <- validate(spec), do: {:ok, spec}
    else
      invalid()
    end
  end

  @doc "Revalidate a specification, including its command, profile, file declarations and budgets."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    with true <- Validation.struct_shape?(spec, __MODULE__),
         :ok <- Command.validate(spec.command),
         :ok <- Profile.validate(spec.profile),
         :ok <- Manifest.validate(spec.inputs, spec.outputs, spec.profile),
         true <- fields?(spec) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_spec), do: invalid()

  @doc "Fingerprint every semantic field with domain separation and a host-owned secret."
  @spec fingerprint(t(), binary()) :: {:ok, String.t()} | {:error, Error.t()}
  def fingerprint(spec, key)
      when is_binary(key) and byte_size(key) >= 32 and byte_size(key) <= 4096 do
    with :ok <- validate(spec) do
      normalized = %{
        spec
        | command: %{spec.command | env: Enum.sort(spec.command.env)},
          inputs: Enum.sort_by(spec.inputs, & &1["path"]),
          outputs: Enum.sort_by(spec.outputs, & &1["path"])
      }

      bytes = :erlang.term_to_binary({"smolbox-spec-v1", canonical(normalized)})
      {:ok, :hmac |> :crypto.mac(:sha256, key, bytes) |> Base.encode16(case: :lower)}
    end
  end

  def fingerprint(_spec, _key), do: invalid()

  defp fields?(spec) do
    Validation.identifier?(spec.scope) and Validation.identifier?(spec.id) and
      artifact?(spec.artifact) and Validation.integer?(spec.queue_ms, 1, 86_400_000) and
      Validation.integer?(spec.retention_ms, 60_000, 2_592_000_000) and metadata?(spec.metadata) and
      spec.command.timeout_secs * 1000 <= spec.profile.execution_ms
  end

  defp artifact?(%{"id" => id, "sha256" => digest, "architecture" => architecture} = artifact) do
    map_size(artifact) == 3 and Validation.identifier?(id) and Validation.digest?(digest) and
      architecture in ["x86_64", "aarch64"]
  end

  defp artifact?(_artifact), do: false

  defp metadata?(metadata) when is_map(metadata) and map_size(metadata) <= 16 do
    Enum.all?(metadata, fn {key, value} -> Validation.identifier?(key) and scalar?(value) end)
  end

  defp metadata?(_metadata), do: false
  defp scalar?(value) when is_boolean(value) or is_nil(value), do: true

  defp scalar?(value) when is_integer(value),
    do: Validation.integer?(value, -9_007_199_254_740_991, 9_007_199_254_740_991)

  defp scalar?(value), do: Validation.text?(value, 256)

  # Tagged shapes avoid map/list/tuple ambiguity. Sorting is explicit across OTP versions.
  defp canonical(%_struct{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value),
    do: {:map, value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical(item)} end)}

  defp canonical(value) when is_list(value), do: {:list, Enum.map(value, &canonical/1)}
  defp canonical(value), do: value

  defp invalid, do: {:error, %Error{category: :validation, operation: :execution_spec}}
end
