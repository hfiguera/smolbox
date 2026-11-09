defmodule SmolBox.Machine do
  @moduledoc """
  Validated observation of a worker machine and its network policy.

  Additive diagnostic fields are ignored. Unsupported network, storage, mount,
  port or accelerator settings fail decoding and cannot be treated as an owned
  machine observation. `created_at` has only second precision upstream and
  is not a cryptographic or immutable ownership token.

  Native observations carry typed receipt evidence in `backend_identity` and use
  nil `created_at`. Running observations also require PID and process birth
  evidence. Restarting the VMM may change that process evidence while preserving
  the full receipt and durable machine incarnation.

  Embedded worker inventory can report a frozen branch source without a receipt.
  """

  alias SmolBox.{Error, MachineSpec, Validation}

  alias SmolBox.Embedded.Identity

  @wire_states ~w(created running stopped)
  @embedded_inventory_states ["frozen" | @wire_states]

  @enforce_keys [:name, :state, :created_at, :cpus, :memory_mb, :storage_gb, :overlay_gb]
  defstruct [
    :name,
    :state,
    :created_at,
    :cpus,
    :memory_mb,
    :storage_gb,
    :overlay_gb,
    backend_identity: nil,
    network: :offline,
    mounts: [],
    ports: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          network: :offline | SmolBox.NetworkPolicy.t(),
          mounts: [SmolBox.Mount.t()],
          ports: [SmolBox.PortMapping.t()],
          state: :created | :running | :stopped | :frozen,
          created_at: non_neg_integer() | nil,
          backend_identity: SmolBox.Embedded.Identity.t() | nil,
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer()
        }

  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(body), do: decode(body, @wire_states)

  defp decode(
         %{
           "name" => name,
           "state" => state,
           "createdAt" => created,
           "cpus" => cpus,
           "memoryMb" => memory,
           "storageGb" => storage,
           "overlayGb" => overlay,
           "mounts" => wire_mounts,
           "ports" => wire_ports,
           "gpu" => false,
           "cuda" => false
         } = wire,
         states
       ) do
    with true <- supported_storage?(wire),
         {:ok, mounts} <- SmolBox.Mount.from_wire(wire_mounts),
         {:ok, ports} <- SmolBox.PortMapping.from_wire(wire_ports),
         {:ok, network} <- decode_network(ports, wire),
         true <-
           MachineSpec.valid_name?(name) and state in states and
             Validation.integer?(created, 0, 253_402_300_799) and
             Validation.integer?(cpus, 1, 64) and Validation.integer?(memory, 128, 16_384) and
             Validation.integer?(storage, 1, 64) and Validation.integer?(overlay, 1, 64) do
      {:ok,
       %__MODULE__{
         name: name,
         network: network,
         ports: ports,
         mounts: mounts,
         state: state(state),
         created_at: created,
         cpus: cpus,
         memory_mb: memory,
         storage_gb: storage,
         overlay_gb: overlay
       }}
    else
      {:error, %Error{category: :unsupported_network_policy}} = error -> error
      _invalid -> invalid()
    end
  end

  defp decode(_body, _states), do: invalid()

  @doc false
  def list_from_wire(values), do: decode_list(values, @wire_states)

  @doc false
  def list_from_embedded_inventory(values) do
    decode_list(values, @embedded_inventory_states)
  end

  defp decode_list(values, states) do
    if Validation.list?(values, 1024) do
      Enum.reduce_while(values, {:ok, []}, &list_entry(&1, &2, states))
      |> case do
        {:ok, machines} -> {:ok, Enum.reverse(machines)}
        error -> error
      end
    else
      {:error, %Error{category: :output_limit, operation: :list, evidence: :dispatch_uncertain}}
    end
  end

  defp list_entry(value, {:ok, machines}, states) do
    case decode(value, states) do
      {:ok, machine} ->
        {:cont, {:ok, [machine | machines]}}

      {:error, error} ->
        {:halt, {:error, %{error | operation: :list, evidence: :dispatch_uncertain}}}
    end
  end

  defp supported_storage?(wire) do
    wire["diskVolumes"] in [nil, []] and is_nil(wire["cacheDisk"]) and
      wire["diskDurability"] in [nil, "full"]
  end

  defp decode_network(ports, wire) do
    with true <- wire["egressRules"] in [nil, []] and is_nil(wire["mediationMachineId"]),
         true <- port_network?(ports, wire),
         {:ok, network} <- SmolBox.NetworkPolicy.from_wire(wire) do
      {:ok, network}
    else
      _invalid -> invalid(:unsupported_network_policy)
    end
  end

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
  def same_incarnation?(
        %__MODULE__{backend_identity: %Identity{} = identity} = expected,
        %__MODULE__{backend_identity: %Identity{} = observed_identity} = observed
      ) do
    Identity.valid?(identity) and
      Identity.valid?(observed_identity) and
      identity.receipt == observed_identity.receipt and
      Map.from_struct(%{expected | state: observed.state, backend_identity: observed_identity}) ==
        Map.from_struct(observed)
  end

  def same_incarnation?(%__MODULE__{} = expected, %__MODULE__{} = observed) do
    Map.from_struct(%{expected | state: observed.state}) == Map.from_struct(observed)
  end

  defp state("created"), do: :created
  defp state("running"), do: :running
  defp state("stopped"), do: :stopped
  defp state("frozen"), do: :frozen

  defp invalid(category \\ :protocol),
    do: {:error, %Error{category: category, operation: :machine}}
end
