defmodule SmolBox.Machine do
  @moduledoc """
  Validated observation of a worker machine and its network policy.

  Additive response fields are ignored. Safety-relevant fields must be present;
  networking without explicit allowlists, mounts, unsupported port mappings, GPU or CUDA fail decoding and cannot be
  treated as an owned machine observation. `created_at` has only second precision upstream and
  is not a cryptographic or immutable ownership token.
  """

  alias SmolBox.{Error, MachineSpec, Validation}

  @enforce_keys [:name, :state, :created_at, :cpus, :memory_mb, :storage_gb, :overlay_gb]
  defstruct [
    :name,
    :state,
    :created_at,
    :cpus,
    :memory_mb,
    :storage_gb,
    :overlay_gb,
    network: :offline,
    ports: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          network: :offline | SmolBox.NetworkPolicy.t(),
          ports: [SmolBox.PortMapping.t()],
          state: :created | :running | :stopped,
          created_at: non_neg_integer(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer()
        }

  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(
        %{
          "name" => name,
          "state" => state,
          "createdAt" => created,
          "cpus" => cpus,
          "memoryMb" => memory,
          "storageGb" => storage,
          "overlayGb" => overlay,
          "mounts" => [],
          "ports" => wire_ports,
          "gpu" => false,
          "cuda" => false
        } = wire
      ) do
    with {:ok, ports} <- SmolBox.PortMapping.from_wire(wire_ports),
         true <- port_network?(ports, wire),
         {:ok, network} <- SmolBox.NetworkPolicy.from_wire(wire),
         true <-
           MachineSpec.valid_name?(name) and state in ["created", "running", "stopped"] and
             Validation.integer?(created, 0, 253_402_300_799) and
             Validation.integer?(cpus, 1, 64) and Validation.integer?(memory, 128, 16_384) and
             Validation.integer?(storage, 1, 64) and Validation.integer?(overlay, 1, 64) do
      {:ok,
       %__MODULE__{
         name: name,
         network: network,
         ports: ports,
         state: state(state),
         created_at: created,
         cpus: cpus,
         memory_mb: memory,
         storage_gb: storage,
         overlay_gb: overlay
       }}
    else
      _invalid -> invalid()
    end
  end

  def from_wire(_body), do: invalid()

  defp port_network?([], _wire), do: true

  defp port_network?(_ports, %{"networkBackend" => "virtio-net", "network" => true}),
    do: true

  defp port_network?(_ports, %{
         "networkBackend" => "virtio-net",
         "network" => false,
         "allowedHosts" => [],
         "allowedCidrs" => []
       }),
       do: true

  defp port_network?(_ports, _wire), do: false

  @doc "Compare creation evidence and allocations; requires exclusive namespace control."
  @spec same_incarnation?(t(), t()) :: boolean()
  def same_incarnation?(%__MODULE__{} = expected, %__MODULE__{} = observed) do
    Map.from_struct(%{expected | state: observed.state}) == Map.from_struct(observed)
  end

  defp state("created"), do: :created
  defp state("running"), do: :running
  defp state("stopped"), do: :stopped
  defp invalid, do: {:error, %Error{category: :protocol, operation: :machine}}
end
