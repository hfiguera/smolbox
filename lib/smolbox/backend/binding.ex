defmodule SmolBox.Backend.Binding do
  @moduledoc """
  Durable embedded target and enrolled data-domain identity.

  This data contains no bridge, helper epoch or runtime handle. It forms part of
  the internal store format; runtime startup verifies the host store's support.
  """
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @enforce_keys [:kind, :target_id, :generation]
  @derive {Inspect, only: [:kind, :target_id]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{kind: :embedded, target_id: String.t(), generation: String.t()}

  @doc false
  def valid?(%__MODULE__{} = binding),
    do:
      Validation.struct_shape?(binding, __MODULE__) and binding.kind == :embedded and
        Validation.identifier?(binding.target_id) and Shape.id?(binding.target_id) and
        Shape.hex?(binding.generation, 32)

  def valid?(_binding), do: false
end
