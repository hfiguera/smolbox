defmodule SmolBox.MachineSpec do
  @moduledoc """
  Create a disposable machine from a host-approved prepared artifact.

  The path is on the worker host, not the Elixir host. The operator must verify
  its immutable digest and architecture before approving it. SmolBox never
  enables networking to fetch a missing image. Starts use `/bin/true` and never
  restart the workload automatically. No host mounts, sockets, GPU, or ports
  are exposed by this contract.

  Disk sizes are requests. SmolVM 1.14.1 copies larger disk templates without
  shrinking them, while its API still reports the request. Low-level callers
  must verify runtime/artifact disk geometry; managed workers require an
  explicit allocation floor. A matching create reply alone is not enforcement.
  """

  alias SmolBox.Error

  @schema [
    cpus: [type: :pos_integer, default: 1],
    memory_mb: [type: :pos_integer, default: 256],
    storage_gb: [type: :pos_integer, default: 1],
    overlay_gb: [type: :pos_integer, default: 1]
  ]

  @enforce_keys [:name, :artifact_path]
  @derive {Inspect, only: [:name, :cpus, :memory_mb]}
  defstruct [:name, :artifact_path, cpus: 1, memory_mb: 256, storage_gb: 1, overlay_gb: 1]

  @type t :: %__MODULE__{
          name: String.t(),
          artifact_path: String.t(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer()
        }

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(name, artifact_path, options \\ []) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- NimbleOptions.validate(options, @schema),
         spec = struct!(__MODULE__, [name: name, artifact_path: artifact_path] ++ options),
         :ok <- validate(spec) do
      {:ok, spec}
    else
      _invalid -> invalid()
    end
  end

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    if SmolBox.Validation.struct_shape?(spec, __MODULE__) and
         valid_name?(spec.name) and artifact_path?(spec.artifact_path) and
         in_range?(spec.cpus, 1..64) and in_range?(spec.memory_mb, 128..16_384) and
         in_range?(spec.storage_gb, 1..64) and in_range?(spec.overlay_gb, 1..64) do
      :ok
    else
      invalid()
    end
  end

  def validate(_spec), do: invalid()

  @doc "Validate the single URL path segment used by machine operations."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) do
    is_binary(name) and byte_size(name) <= 31 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)
  end

  @spec to_wire(t()) :: {:ok, map()} | {:error, Error.t()}
  def to_wire(spec) do
    with :ok <- validate(spec) do
      {:ok,
       %{
         "name" => spec.name,
         "from" => spec.artifact_path,
         "cpus" => spec.cpus,
         "memoryMb" => spec.memory_mb,
         "storageGb" => spec.storage_gb,
         "overlayGb" => spec.overlay_gb,
         "network" => false,
         "gpu" => false,
         "cuda" => false,
         "dockerSocket" => false,
         "mounts" => [],
         "ports" => [],
         "entrypoint" => ["/bin/true"],
         "cmd" => [],
         "restart" => %{"policy" => "never"}
       }}
    end
  end

  defp artifact_path?(path) do
    is_binary(path) and byte_size(path) <= 1024 and String.valid?(path) and
      String.starts_with?(path, "/") and String.ends_with?(path, ".smolmachine") and
      not String.contains?(path, ["\0", "/../", "/./", "//"])
  end

  defp in_range?(value, range), do: is_integer(value) and value in range
  defp invalid, do: {:error, %Error{category: :validation, operation: :machine_spec}}
end
