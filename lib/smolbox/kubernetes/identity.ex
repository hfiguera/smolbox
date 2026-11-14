defmodule SmolBox.Kubernetes.Identity do
  @moduledoc false
  alias SmolBox.Kubernetes.{Assignment, Receipt}
  alias SmolBox.Validation

  @enforce_keys [:receipt]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
  @type t :: %__MODULE__{receipt: Receipt.t()}

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and Receipt.valid?(value.receipt)

  def valid?(_value), do: false

  def matches?(%__MODULE__{} = value, assignment),
    do:
      valid?(value) and Assignment.valid?(assignment) and
        Receipt.matches_assignment?(value.receipt, assignment)

  def matches?(_identity, _assignment), do: false

  def same_incarnation?(left, right),
    do: valid?(left) and valid?(right) and Receipt.same_incarnation?(left.receipt, right.receipt)
end
