defmodule SmolBox.Runtime.WorkerReports do
  @moduledoc false
  alias SmolBox.{AdmissionReport, Client, Error, Profile, Validation, WorkerReport}
  alias SmolBox.Runtime.{Session, WorkerConfig}

  def observe(config, worker, snapshot) do
    {used, remaining, usage_error} = accounting(config, worker)

    client = %{
      worker.client
      | worker: %{
          worker.client.worker
          | operation_timeout_ms: min(500, worker.client.worker.operation_timeout_ms),
            max_response_bytes: min(8192, worker.client.worker.max_response_bytes)
        }
    }

    {capacity, capacity_error} =
      case Client.capacity(client) do
        {:ok, capacity} -> {capacity, nil}
        {:error, error} -> {nil, error}
      end

    %WorkerReport{
      worker: snapshot,
      reserved: used,
      remaining: remaining,
      usage_error: usage_error,
      observed_capacity: capacity,
      capacity_error: capacity_error,
      checked_at_ms: config.clock.now()
    }
  end

  def admission(config, spec, snapshots) do
    required = Profile.resources(spec.profile)

    Enum.zip_with(config.workers, snapshots, fn worker, snapshot ->
      {used, remaining, error} = accounting(config, worker)
      blockers = if snapshot.status == :ready, do: [], else: [snapshot.status]

      blockers =
        if WorkerConfig.supports?(worker, spec),
          do: blockers,
          else: blockers ++ [:unsupported_spec]

      %AdmissionReport{
        worker: snapshot,
        required: required,
        reserved: used,
        remaining: remaining,
        usage_error: error,
        checked_at_ms: config.clock.now(),
        blockers: blockers ++ shortages(remaining, required)
      }
    end)
  end

  defp shortages(nil, _required), do: [:store_unavailable]

  defp shortages(remaining, required),
    do:
      for(
        resource <- [:slots, :cpus, :memory_mb, :disk_gb],
        remaining[resource] < required[resource],
        do: {:capacity, resource}
      )

  defp accounting(config, worker) do
    case Session.store(config, :usage, [worker.client.worker.id]) do
      {:ok, used} when is_map(used) ->
        project(used, worker.capacity)

      _failed ->
        unavailable_usage()
    end
  end

  defp project(used, capacity) do
    if valid_usage?(used) do
      remaining =
        Map.new(capacity, fn {resource, limit} ->
          {resource, max(0, limit - used[resource])}
        end)

      {used, remaining, nil}
    else
      unavailable_usage()
    end
  end

  defp valid_usage?(used) do
    Enum.sort(Map.keys(used)) == [:cpus, :disk_gb, :memory_mb, :slots] and
      Enum.all?(Map.values(used), &Validation.integer?(&1, 0, 18_446_744_073_709_551_615))
  end

  defp unavailable_usage, do: {nil, nil, %Error{category: :store, operation: :usage}}
end
