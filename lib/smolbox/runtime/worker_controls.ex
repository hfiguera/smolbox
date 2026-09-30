defmodule SmolBox.Runtime.WorkerControls do
  @moduledoc false
  alias SmolBox.Runtime.Session
  alias SmolBox.{Telemetry, Validation, WorkerControl, WorkerMaintenance}

  def read(%{worker_control: false}, _id),
    do: Session.error(:unsupported_capability, :worker_control)

  def read(config, id) do
    case Session.store(config, :worker_control, [id]) do
      {:ok, %WorkerControl{worker_id: ^id} = control} ->
        if WorkerControl.validate(control) == :ok,
          do: {:ok, control},
          else: Session.error(:store, :worker_control)

      {:error, _} = error ->
        error

      _ ->
        Session.error(:store, :worker_control)
    end
  end

  def change(config, id, mode, expected) do
    with {:ok, worker} <- configured(config, id),
         :ok <- supported(config),
         false <- mode == :active and worker.draining,
         {:ok, control} <-
           Session.store(config, :set_worker_mode, [id, mode, expected, config.clock.now()]) do
      Telemetry.worker(
        config.telemetry_table,
        worker,
        if(mode == :draining, do: :draining, else: :unavailable)
      )

      {:ok, control}
    else
      true -> Session.error(:unsupported_capability, :worker_control)
      error -> error
    end
  end

  def maintenance(config, id, options) do
    with true <- Validation.keys?(options, [:cursor, :limit]),
         {:ok, _} <- configured(config, id),
         :ok <- supported(config),
         cursor = Keyword.get(options, :cursor),
         limit = Keyword.get(options, :limit, 20),
         true <- WorkerMaintenance.valid_page?(id, cursor, limit) do
      Session.store(config, :worker_maintenance, [id, cursor, limit, config.clock.now()])
    else
      false -> Session.error(:validation, :worker_maintenance)
      error -> error
    end
  end

  def reports(%{worker_control: false}, snapshots), do: snapshots

  def reports(config, snapshots) do
    Enum.zip_with(config.workers, snapshots, &report(config, &1, &2))
  end

  defp report(config, worker, snapshot) do
    case read(config, worker.client.worker.id) do
      {:ok, control} ->
        status =
          if worker.draining or control.mode == :draining,
            do: :draining,
            else: snapshot.health_status

        Map.merge(snapshot, %{status: status, admission_control: control, admission_error: nil})

      {:error, error} ->
        Map.merge(snapshot, %{
          status: :unavailable,
          admission_control: nil,
          admission_error: error
        })
    end
  end

  def mode(%{worker_control: false}, _id), do: :active

  def mode(config, id) do
    case read(config, id) do
      {:ok, control} -> control.mode
      _ -> :unavailable
    end
  end

  defp supported(%{worker_control: true}), do: :ok
  defp supported(_), do: Session.error(:unsupported_capability, :worker_control)

  defp configured(config, id) do
    case Enum.find(config.workers, &(&1.client.worker.id == id)) do
      nil -> Session.error(:not_found, :worker)
      worker -> {:ok, worker}
    end
  end
end
