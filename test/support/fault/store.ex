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

    with :ok <- failure(context.faults, event, :before) do
      FaultGate.hit(context.faults, event, :before)
      result = apply(Map.get(context, :adapter, Memory), operation, [context.store | arguments])
      FaultGate.hit(context.faults, event, :after)
      with :ok <- failure(context.faults, event, :after), do: result
    end
  end

  defp failure(nil, _event, _phase), do: :ok

  defp failure(gate, event, phase) do
    Agent.get_and_update(gate, fn
      %{failure: {^event, ^phase}, observer: observer} = state ->
        send(observer, {:store_failure, event, phase})

        {{:error, %SmolBox.Error{category: :store, operation: :store}},
         Map.delete(state, :failure)}

      state ->
        {:ok, state}
    end)
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

  defp event(:machine, [:claim, _arguments]), do: :machine_claim

  defp event(:machine, [:write, [_key, _guard, changes, _now]]) do
    cond do
      changes[:phase] == :prepared -> :source_prepared
      changes[:phase] == :preparing -> :source_preparing
      true -> :machine_write
    end
  end

  defp event(:machine, [:export_advance, [_key, _guard, _id, _expected, changes, _now]]) do
    case changes[:state] do
      :dispatching -> :export_intent
      :verifying -> :export_receipt
      :published -> :export_result
      _other -> :export_write
    end
  end

  defp event(:machine, [:capture_advance, [_key, _guard, _id, _expected, changes, _now]]) do
    case changes[:state] do
      :dispatching -> :capture_intent
      :captured -> :capture_result
      _ -> :capture_write
    end
  end

  defp event(:machine, [:branch_advance, [_key, _guard, _id, _expected, change, _now]]) do
    case change do
      :dispatching -> :branch_intent
      {:observed, _} -> :branch_receipt
      {:complete, _} -> :branch_complete
      _ -> :branch_write
    end
  end

  defp event(:machine, [:branch_release_advance, [_key, _guard, _expected, change, _now]]) do
    case change do
      :dispatching -> :release_intent
      {:complete, _} -> :release_result
      _ -> :release_write
    end
  end

  defp event(operation, _arguments), do: operation
end
