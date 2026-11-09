defmodule SmolBox.Backend.Budget do
  @moduledoc """
  Total operation time and encoded input/output limits supplied to a backend.

  Runtime constraints may only reduce a target's configured budgets. Backend
  implementations enforce these limits independently of their transport and
  preserve uncertain outcomes when observation ends before command completion.
  """
  alias SmolBox.Validation

  @enforce_keys [:timeout_ms, :max_request_bytes, :max_response_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_request_bytes: pos_integer(),
          max_response_bytes: pos_integer()
        }

  @doc false
  def valid?(%__MODULE__{} = budget),
    do:
      Validation.struct_shape?(budget, __MODULE__) and
        Enum.all?(@enforce_keys, &Validation.integer?(Map.fetch!(budget, &1), 1, 4_294_967_295))

  def valid?(_), do: false

  @doc false
  def constrain(%__MODULE__{} = budget, options) do
    if Validation.keys?(options, @enforce_keys) and
         Enum.all?(options, fn {_key, value} -> Validation.integer?(value, 1, 4_294_967_295) end) do
      {:ok,
       Enum.reduce(options, budget, fn {key, value}, current ->
         Map.update!(current, key, &min(&1, value))
       end)}
    else
      {:error, %SmolBox.Error{category: :validation, operation: :backend}}
    end
  end

  @doc false
  def until(budget, deadline, operation) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: constrain(budget, timeout_ms: timeout),
      else:
        {:error,
         %SmolBox.Error{category: :expired, operation: operation, evidence: :not_dispatched}}
  end
end
