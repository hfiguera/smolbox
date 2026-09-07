defmodule SmolBox.FaultStore do
  @moduledoc false
  @behaviour SmolBox.Store
  alias SmolBox.FaultGate
  alias SmolBox.Store.Memory

  for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks) do
    arguments = Macro.generate_arguments(arity - 1, __MODULE__)
    @impl SmolBox.Store
    def unquote(operation)(context, unquote_splicing(arguments)),
      do: invoke(context, unquote(operation), [unquote_splicing(arguments)])
  end

  defp invoke(context, operation, arguments) do
    event = event(operation, arguments)
    FaultGate.hit(context.faults, event, :before)
    result = apply(Memory, operation, [context.store | arguments])
    FaultGate.hit(context.faults, event, :after)
    result
  end

  defp event(:write, [_key, _guard, changes, _now]) do
    cond do
      Keyword.has_key?(changes, :created_machine) -> :creation_record
      Keyword.has_key?(changes, :artifacts) -> :artifact_record
      Keyword.has_key?(changes, :result) -> :result_write
      changes[:state] == :dispatching -> :dispatch_intent
      changes[:state] == :running -> :first_output_record
      changes[:state] == :completed -> :completion_record
      changes[:cleanup] == :complete -> :absence_record
      true -> :store_write
    end
  end

  defp event(operation, _arguments), do: operation
end
