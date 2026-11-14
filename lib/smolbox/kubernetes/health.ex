defmodule SmolBox.Kubernetes.Health do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.{Config, Enrollment, Operation}

  def observe(config, expected, budget) do
    if expected == config.runtime_version do
      case check(config, budget) do
        {:ok, value} -> {:ready, value}
        _ -> {:unavailable, nil}
      end
    else
      {:incompatible, nil}
    end
  end

  def check(config, budget) do
    with true <- config.controller_guard != nil and config.controller_guard.enrolled,
         {:ok, bounded} <- Budget.constrain(budget, timeout_ms: 5000),
         {:ok, operation} <- Operation.new(config, bounded, :worker),
         do: Operation.run(operation, fn _sent -> inspect_node(operation) end),
         else: (_ -> Operation.error(:identity_conflict, :worker, :not_dispatched))
  end

  def node_status(operation) do
    {provider, context} = operation.config.node_evidence

    with {:ok, budget} <- Operation.node_budget(operation),
         {:ok, %{complete_history: true} = value} <-
           provider.check(Config.binding(operation.config), budget, context),
         do: {:ok, value},
         else: (_ -> Operation.error(:identity_conflict, :worker, :not_dispatched))
  end

  defp inspect_node(operation) do
    with :ok <- Enrollment.observe(operation), {:ok, value} <- node_status(operation) do
      {:ok,
       Map.merge(value, %{backend: :kubernetes, runtime_version: operation.config.runtime_version})}
    end
  end
end
