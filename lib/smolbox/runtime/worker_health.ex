defmodule SmolBox.Runtime.WorkerHealth do
  @moduledoc false
  alias SmolBox.{Client, Error}

  def check(worker, clock) do
    case observe(worker, clock) do
      %{status: :ready} ->
        :ok

      _ ->
        {:error,
         %Error{category: :unsupported_capability, operation: :worker, evidence: :not_dispatched}}
    end
  end

  def observe(worker, clock) do
    client = %{
      worker.client
      | worker: %{
          worker.client.worker
          | operation_timeout_ms: 500,
            max_response_bytes: min(4096, worker.client.worker.max_response_bytes)
        }
    }

    result =
      case Client.health(client) do
        {:ok, health} -> {classify(client, health, worker.runtime_version), health}
        _failed -> {:unavailable, nil}
      end

    {status, health} = result

    %{
      status: status,
      health: health,
      checked_at_ms: clock.now(),
      checked_monotonic: clock.monotonic()
    }
  end

  def status(%{status: status, checked_monotonic: checked}, monotonic)
      when monotonic >= checked and monotonic - checked <= 5000,
      do: status

  def status(_missing_or_stale, _monotonic), do: :unavailable

  defp classify(_client, %{version: actual}, expected) when actual != expected,
    do: :incompatible

  defp classify(_client, %{total: nil}, _expected), do: :degraded

  defp classify(client, _health, _expected) do
    case Client.readiness(client) do
      :ok -> :ready
      _failed -> :degraded
    end
  end
end
