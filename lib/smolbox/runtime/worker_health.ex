defmodule SmolBox.Runtime.WorkerHealth do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{Backend, Error}

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
    {status, health} = Backend.observe_health(Target.connection(worker), worker.runtime_version)

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
end
