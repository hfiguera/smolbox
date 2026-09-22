defmodule SmolBox.Store.CodecExecution do
  @moduledoc false
  alias SmolBox.{Command, Error, Execution, ManagedMachine, Validation}

  def upgrade(%Execution{spec: %{command: command, profile: %{execution_ms: ms}}} = record) do
    expected = Command |> struct() |> Map.keys() |> List.delete(:background) |> Enum.sort()

    if is_map(command) and Enum.sort(Map.keys(command)) == expected and
         command.__struct__ == Command and Validation.integer?(command.timeout_secs, 1, 300) and
         Validation.integer?(ms, 1000, 300_000) do
      {:ok, %{record | spec: %{record.spec | command: Map.put(command, :background, false)}}}
    else
      invalid()
    end
  end

  def upgrade(%ManagedMachine{spec: %{profile: %{execution_ms: ms}}} = record) do
    if Validation.integer?(ms, 1000, 300_000), do: {:ok, record}, else: invalid()
  end

  def upgrade(_record), do: invalid()

  def strip(%Execution{} = record),
    do: %{record | spec: %{record.spec | command: Map.delete(record.spec.command, :background)}}

  def strip(record), do: record

  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
