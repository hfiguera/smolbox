defmodule SmolBox.Backend.Reference do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Validation

  @enforce_keys [:adapter, :kind, :id, :context, :budget]
  @derive {Inspect, only: [:kind, :id]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          adapter: module(),
          kind: :http | :embedded | :kubernetes,
          id: String.t(),
          context: term(),
          budget: Budget.t()
        }

  def valid?(%__MODULE__{} = reference) do
    Validation.struct_shape?(reference, __MODULE__) and
      reference.kind in [:http, :embedded, :kubernetes] and
      Validation.identifier?(reference.id) and Budget.valid?(reference.budget) and
      is_atom(reference.adapter) and Code.ensure_loaded?(reference.adapter) and
      function_exported?(reference.adapter, :invoke, 4) and
      function_exported?(reference.adapter, :supports_operation?, 2)
  end

  def valid?(_), do: false
end
