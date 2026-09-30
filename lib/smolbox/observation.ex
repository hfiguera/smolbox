defmodule SmolBox.Observation do
  @moduledoc false
  alias SmolBox.{Error, Validation}

  def counters(body, fields, required, operation) when is_map(body) do
    values = Map.new(fields, fn {field, wire} -> {field, Map.get(body, wire)} end)

    if Enum.all?(values, fn {field, value} ->
         (is_nil(value) and field not in required) or
           Validation.integer?(value, 0, 18_446_744_073_709_551_615)
       end) do
      {:ok, values}
    else
      invalid(operation)
    end
  end

  def counters(_body, _fields, _required, operation), do: invalid(operation)
  def invalid(operation), do: {:error, %Error{category: :protocol, operation: operation}}
end
