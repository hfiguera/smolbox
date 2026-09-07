defmodule SmolBox.Runtime.Coordinator do
  @moduledoc false
  use GenServer

  alias SmolBox.Execution
  alias SmolBox.Runtime.{Executor, Session, WorkerHealth}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init({config, parent}) do
    state = %{
      config: config,
      parent: parent,
      tasks: nil,
      active: %{},
      scan: nil,
      health: %{},
      draining: MapSet.new(),
      cursor: nil,
      health_at: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    {Task.Supervisor, tasks, :supervisor, _modules} =
      Enum.find(Supervisor.which_children(state.parent), &(elem(&1, 0) == Task.Supervisor))

    send(self(), :tick)
    {:noreply, %{state | tasks: tasks}}
  end

  @impl GenServer
  def handle_call(:config, _from, state), do: {:reply, {:ok, state.config}, state}

  def handle_call(:workers, _from, state) do
    reports =
      Enum.map(state.config.workers, fn worker ->
        id = worker.client.worker.id

        %{
          id: id,
          status: status(state, worker),
          qualification: worker.qualification,
          architecture: worker.architecture,
          platform: worker.platform,
          runtime_version: worker.runtime_version,
          health: get_in(state.health, [id, :health]),
          health_checked_at_ms: get_in(state.health, [id, :checked_at_ms])
        }
      end)

    {:reply, {:ok, reports}, state}
  end

  def handle_call({:drain, id}, _from, state) do
    if Enum.any?(state.config.workers, &(&1.client.worker.id == id)),
      do: {:reply, :ok, %{state | draining: MapSet.put(state.draining, id)}},
      else: {:reply, Session.error(:not_found, :worker), state}
  end

  def handle_call({:reconcile, key}, _from, state) do
    cond do
      key in Map.values(state.active) ->
        {:reply, :ok, state}

      map_size(state.active) >= state.config.max_active ->
        {:reply, Session.error(:admission_exhausted, :reconcile), state}

      true ->
        {:reply, :ok, launch(state, key)}
    end
  end

  @impl GenServer
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.config.poll_ms)

    if state.scan do
      {:noreply, state}
    else
      refresh = state.health_at == nil or state.config.clock.monotonic() - state.health_at >= 5000

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          scan_safely(state, refresh)
        end)

      {:noreply, %{state | scan: task.ref}}
    end
  end

  def handle_info(
        {reference, {:scan, health, records, cursor, refreshed}},
        %{scan: reference} = state
      ) do
    Process.demonitor(reference, [:flush])

    next = %{
      state
      | scan: nil,
        health: health,
        cursor: cursor,
        health_at: if(refreshed, do: state.config.clock.monotonic(), else: state.health_at)
    }

    {:noreply, Enum.reduce(records, next, &launch(&2, Execution.key(&1)))}
  end

  def handle_info({reference, _result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, forget(state, reference)}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state),
    do: {:noreply, forget(state, reference)}

  defp forget(state, reference) do
    if state.scan == reference,
      do: %{state | scan: nil},
      else: %{state | active: Map.delete(state.active, reference)}
  end

  defp launch(state, key) do
    if map_size(state.active) < state.config.max_active and key not in Map.values(state.active) do
      eligible =
        for worker <- state.config.workers,
            status(state, worker) == :ready,
            do: worker.client.worker.id

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          Executor.run(state.config, key, eligible)
        end)

      %{state | active: Map.put(state.active, task.ref, key)}
    else
      state
    end
  end

  defp status(state, worker) do
    if worker.draining or MapSet.member?(state.draining, worker.client.worker.id),
      do: :draining,
      else:
        WorkerHealth.status(
          Map.get(state.health, worker.client.worker.id),
          state.config.clock.monotonic()
        )
  end

  defp scan(config, cursor, previous, refresh) do
    health =
      config.workers
      |> Task.async_stream(&probe(config, &1, previous, refresh),
        max_concurrency: 4,
        timeout: config.lease_ms,
        on_timeout: :kill_task
      )
      |> Enum.zip(config.workers)
      |> Map.new(fn
        {{:ok, status}, worker} -> {worker.client.worker.id, status}
        {_failed, worker} -> {worker.client.worker.id, nil}
      end)

    case Session.store(config, :due, [config.clock.now(), cursor, 100]) do
      {:ok, records, next} -> {:scan, health, records, next, refresh}
      _failed -> {:scan, health, [], nil, refresh}
    end
  end

  defp scan_safely(state, refresh),
    do: Session.safe(fn -> scan(state.config, state.cursor, state.health, refresh) end)

  defp probe(config, worker, previous, refresh) do
    id = worker.client.worker.id

    case Session.store(config, :claim_worker, [
           id,
           config.owner,
           config.clock.now(),
           config.lease_ms
         ]) do
      {:ok, _lease} ->
        if refresh,
          do: WorkerHealth.observe(worker, config.clock),
          else: Map.get(previous, id)

      _failed ->
        nil
    end
  end
end
