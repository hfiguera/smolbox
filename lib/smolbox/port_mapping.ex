defmodule SmolBox.PortMapping do
  @moduledoc """
  A fixed TCP port on the worker host forwarded to a guest TCP port.

  Both ports must be in 1–65,535. Mappings do not start or supervise a service.
  The worker controls listener binding; no per-machine address or UDP option is
  supported. A canonical list has at most 32 entries and unique host ports.
  """
  alias SmolBox.{Error, Validation}

  @enforce_keys [:host, :guest]
  defstruct @enforce_keys
  @type t :: %__MODULE__{host: pos_integer(), guest: pos_integer()}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      mapping = struct!(__MODULE__, options)
      if valid?(mapping), do: {:ok, mapping}, else: invalid()
    else
      invalid()
    end
  end

  @doc false
  def valid?(%__MODULE__{} = mapping),
    do:
      Validation.struct_shape?(mapping, __MODULE__) and
        Validation.integer?(mapping.host, 1, 65_535) and
        Validation.integer?(mapping.guest, 1, 65_535)

  def valid?(_mapping), do: false

  @doc "Validate and sort a list without silently removing duplicate host ports."
  def normalize(mappings) do
    if Validation.list?(mappings, 32) and Enum.all?(mappings, &valid?/1) and
         length(mappings) == MapSet.size(MapSet.new(mappings, & &1.host)),
       do: {:ok, Enum.sort_by(mappings, & &1.host)},
       else: invalid()
  end

  @doc false
  def canonical?(mappings), do: normalize(mappings) == {:ok, mappings}

  @doc false
  def to_wire(mappings), do: Enum.map(mappings, &%{"host" => &1.host, "guest" => &1.guest})

  @doc false
  def from_wire(mappings) do
    if Validation.list?(mappings, 32),
      do: mappings |> Enum.map(&wire_entry/1) |> normalize(),
      else: invalid()
  end

  defp wire_entry(%{"host" => host, "guest" => guest} = entry) when map_size(entry) == 2,
    do: %__MODULE__{host: host, guest: guest}

  defp wire_entry(_entry), do: nil

  defp invalid, do: {:error, %Error{category: :validation, operation: :machine_spec}}
end
