defmodule SmolBox.MachineSpec do
  @moduledoc """
  Create a machine from a host-approved prepared artifact.

  The path is on the worker host, not the Elixir host. `source: :checkpoint`
  selects an approved idle `.smolcheckpoint` instead of an image. It requires
  smolvm 1.16.1, 1.17.0 or 1.19.0 and offline networking. Captured CPU/memory/disks must match the
  specification; disk and entrypoint override fields are omitted on the wire.
  Checkpoints resume captured processes: the caller must approve their idle state,
  no secrets and disabled workload restart before creation. See `SmolBox.Checkpoint`.

  For the default `source: :image`, the operator must verify
  its immutable digest and architecture before approving it. SmolBox never
  enables networking to fetch a missing image. Starts use `/bin/true` unless an
  explicit `SmolBox.Workload` is supplied on smolvm 1.17.0 or 1.19.0. Automatic workload
  restart is unsupported. Networking is offline unless an explicit
  `SmolBox.NetworkPolicy` is supplied. Optional `:ports` publishes fixed TCP
  mappings on smolvm 1.17.0 or 1.19.0 using virtio-net, independently of outbound policy.
  Offline with mappings means denied outbound, not absence of a network device.
  No host mounts, Unix sockets or GPU are exposed. See [Port mappings](port-mappings.html).

  Disk sizes are requests. smolvm 1.14.1 copies larger disk templates without
  shrinking them, while its API still reports the request. Low-level callers
  must verify runtime/artifact disk geometry; managed workers require an
  explicit allocation floor. A matching create reply alone is not enforcement.

  smolvm 1.14.6, 1.16.0, 1.16.1, 1.17.0 and 1.19.0 need the host's `resize2fs` for requests
  below template sizes. Missing it caused file loss after stop/start in validation. Verify
  the host prerequisite and persistence before admitting work; see
  [Compatibility](compatibility.html#macos-1-14-6-prerequisites).
  """

  alias SmolBox.Error

  @schema [
    ports: [type: :any, default: []],
    workload: [type: :any, default: nil],
    source: [type: {:in, [:image, :checkpoint]}, default: :image],
    network: [type: :any, default: :offline],
    cpus: [type: :pos_integer, default: 1],
    memory_mb: [type: :pos_integer, default: 256],
    storage_gb: [type: :pos_integer, default: 1],
    overlay_gb: [type: :pos_integer, default: 1]
  ]

  @enforce_keys [:name, :artifact_path]
  @derive {Inspect, only: [:name, :cpus, :memory_mb]}
  defstruct [
    :name,
    :artifact_path,
    ports: [],
    workload: nil,
    source: :image,
    network: :offline,
    cpus: 1,
    memory_mb: 256,
    storage_gb: 1,
    overlay_gb: 1
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          source: :image | :checkpoint,
          ports: [SmolBox.PortMapping.t()],
          workload: SmolBox.Workload.t() | nil,
          network: :offline | SmolBox.NetworkPolicy.t(),
          artifact_path: String.t(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer()
        }

  @doc """
  Describe a machine using a name and absolute artifact path on the worker.

  `:source` defaults to `:image` (`.smolmachine`). `:checkpoint` requires an idle,
  offline `.smolcheckpoint` and smolvm 1.16.1, 1.17.0 or 1.19.0. Allocations describe its captured
  topology; they cannot resize it.

  Names have at most 31 lowercase letters, digits, underscores or hyphens and
  start with a letter/digit; `SmolBox.Identity.machine_name/1` generates opaque
  names. Options include `:ports` (up to 32 `SmolBox.PortMapping` values, image sources
  only), `:network` (offline or `SmolBox.NetworkPolicy`) and `:cpus` (default 1, range 1–64), `:memory_mb` (256, 128–16,384),
  `:storage_gb` and `:overlay_gb` (each 1, range 1–64). For the reference templates,
  explicitly request 20/10 GiB disks. Construction does not read the artifact.

  Pass the validated value to `SmolBox.Client.create/2`. Use `SmolBox.Profile`
  and `SmolBox.ExecutionSpec` for managed submissions instead.
  """
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(name, artifact_path, options \\ []) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- NimbleOptions.validate(options, @schema),
         {:ok, ports} <- SmolBox.PortMapping.normalize(options[:ports]),
         options = Keyword.put(options, :ports, ports),
         spec = struct!(__MODULE__, [name: name, artifact_path: artifact_path] ++ options),
         :ok <- validate(spec) do
      {:ok, spec}
    else
      _invalid -> invalid()
    end
  end

  @doc "Revalidate the machine name, worker artifact path and allocation bounds."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    if SmolBox.Validation.struct_shape?(spec, __MODULE__) and
         valid_name?(spec.name) and artifact_path?(spec.artifact_path, spec.source) and
         network_valid?(spec) and
         SmolBox.PortMapping.canonical?(spec.ports) and
         workload_valid?(spec) and
         allocations?(spec) do
      :ok
    else
      invalid()
    end
  end

  def validate(_spec), do: invalid()

  defp workload_valid?(spec),
    do:
      SmolBox.Workload.optional?(spec.workload) and
        (spec.workload == nil or spec.source == :image)

  defp allocations?(spec),
    do:
      in_range?(spec.cpus, 1..64) and in_range?(spec.memory_mb, 128..16_384) and
        in_range?(spec.storage_gb, 1..64) and in_range?(spec.overlay_gb, 1..64)

  @doc "Validate the single URL path segment used by machine operations."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) do
    is_binary(name) and byte_size(name) <= 31 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)
  end

  @doc "Encode the creation request and explicit network policy after validation."
  @spec to_wire(t()) :: {:ok, map()} | {:error, Error.t()}
  def to_wire(spec) do
    with :ok <- validate(spec) do
      {:ok,
       wire_source(
         spec,
         Map.merge(
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
             "ports" => SmolBox.PortMapping.to_wire(spec.ports),
             "entrypoint" => ["/bin/true"],
             "cmd" => [],
             "restart" => %{"policy" => "never"}
           },
           Map.merge(network_wire(spec), workload_wire(spec))
         )
       )}
    end
  end

  defp workload_wire(%{workload: nil}), do: %{}
  defp workload_wire(%{workload: workload}), do: SmolBox.Workload.to_wire(workload)

  defp wire_source(%{source: :checkpoint}, wire),
    do: Map.drop(wire, ["storageGb", "overlayGb", "entrypoint", "cmd"])

  defp wire_source(_spec, wire), do: wire

  defp network_wire(%{ports: [_ | _], network: :offline}),
    do: %{
      "network" => false,
      "networkBackend" => "virtio-net",
      "allowedHosts" => [],
      "allowedCidrs" => []
    }

  defp network_wire(spec), do: SmolBox.NetworkPolicy.to_wire(spec.network)

  defp network_valid?(%{source: :checkpoint, network: network, ports: ports}),
    do: network == :offline and ports == []

  defp network_valid?(%{network: network}), do: SmolBox.NetworkPolicy.valid?(network)

  defp artifact_path?(path, source) when source in [:image, :checkpoint] do
    is_binary(path) and byte_size(path) <= 1024 and String.valid?(path) and
      String.starts_with?(path, "/") and
      String.ends_with?(
        path,
        if(source == :checkpoint, do: ".smolcheckpoint", else: ".smolmachine")
      ) and
      not String.contains?(path, ["\0", "/../", "/./", "//"])
  end

  defp artifact_path?(_path, _source), do: false

  defp in_range?(value, range), do: is_integer(value) and value in range
  defp invalid, do: {:error, %Error{category: :validation, operation: :machine_spec}}
end
