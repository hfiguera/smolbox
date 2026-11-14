defmodule SmolBox.Kubernetes.Controller do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Kubernetes.{Config, LabController}

  # Internal assigned component probes retain their explicit nil-guard path.
  # Public runtime admission separately requires acquired/enrolled authority.
  def authorize(%{controller_guard: nil}, _budget, _bytes), do: :ok

  def authorize(config, budget, bytes) do
    case :atomics.get(bytes, 3) do
      2 -> :ok
      0 -> first(config, budget, bytes)
      _ -> unavailable()
    end
  end

  defp first(config, budget, bytes) do
    if :atomics.compare_exchange(bytes, 3, 0, 1) == :ok do
      result = check(config, budget, bytes)
      :atomics.put(bytes, 3, if(result == :ok, do: 2, else: -1))
      result
    else
      unavailable()
    end
  end

  defp check(config, budget, bytes) do
    request = min(65_544, div(budget.max_request_bytes - :atomics.get(bytes, 1), 4))
    response = min(65_544, div(budget.max_response_bytes - :atomics.get(bytes, 2), 4))

    if request > 0 and response > 0 do
      :atomics.add_get(bytes, 1, request)
      :atomics.add_get(bytes, 2, response)
      granted = %{budget | max_request_bytes: request, max_response_bytes: response}
      LabController.check(Config.binding(config), granted, config.controller_guard)
    else
      unavailable()
    end
  end

  defp unavailable,
    do:
      {:error,
       %Error{category: :identity_conflict, operation: :reconcile, evidence: :not_dispatched}}
end
