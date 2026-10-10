defmodule SmolBox.Runtime.Coordinator do
  @moduledoc false
  use GenServer

  alias SmolBox.{Execution, Telemetry}
  alias SmolBox.Runtime.{Executor, Machines, Session, WorkerControls, WorkerHealth}
  alias SmolBox.Telemetry.Dispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init({config, parent}) do
    state = %{
      config: config,
      parent: parent,
      tasks: nil,
      active: %{},
      maintenance: MapSet.new(),
      scan: nil,
      health: %{},
      cursor: nil,
      machine_cursor: nil,
      machines_first: false,
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

  def handle_call({:lookup_terminal, key}, _from, state) do
    result =
      case :ets.lookup(state.config.terminal_table, key) do
        [{^key, handle}] -> {:ok, handle}
        [] -> :pending
      end

    {:reply, result, state}
  end

  def handle_call(:telemetry_stats, _from, state),
    do: {:reply, {:ok, Dispatcher.stats(state.config.telemetry_table)}, state}

  def handle_call(:workers, _from, state) do
    reports =
      Enum.map(state.config.workers, fn worker ->
        id = worker.client.worker.id

        %{
          id: id,
          status: status(state, worker),
          health_status: health_status(state, worker),
          qualification: worker.qualification,
          architecture: worker.architecture,
          platform: worker.platform,
          runtime_version: worker.runtime_version,
          allocation_floor: worker.allocation_floor,
          capacity: worker.capacity,
          health: get_in(state.health, [id, :health]),
          health_checked_at_ms: get_in(state.health, [id, :checked_at_ms])
        }
      end)

    {:reply, {:ok, reports}, state}
  end

  def handle_call({:reconcile, key, record}, _from, state) do
    lane = lane(record, state.config.clock.now())

    cond do
      key in Map.values(state.active) ->
        {:reply, :ok, state}

      not available?(state, lane) ->
        {:reply, Session.error(:admission_exhausted, :reconcile), state}

      true ->
        {:reply, :ok, launch(state, {key, lane})}
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
        {reference, {:scan, health, records, cursor, machines, machine_cursor, refreshed}},
        %{scan: reference} = state
      ) do
    Process.demonitor(reference, [:flush])

    next = %{
      state
      | scan: nil,
        health: health,
        cursor: cursor,
        machine_cursor: machine_cursor,
        health_at: if(refreshed, do: state.config.clock.monotonic(), else: state.health_at)
    }

    for worker <- state.config.workers,
        status(state, worker) != status(next, worker),
        do: Telemetry.worker(state.config.telemetry_table, worker, status(next, worker))

    machine_keys = Enum.map(machines, &{{:machine, {&1.scope, &1.id}}, :maintenance})
    command_keys = Enum.map(records, &{Execution.key(&1), lane(&1, state.config.clock.now())})

    keys =
      if state.machines_first,
        do: machine_keys ++ command_keys,
        else: command_keys ++ machine_keys

    {:noreply,
     Enum.reduce(keys, %{next | machines_first: not state.machines_first}, &launch(&2, &1))}
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
      else: %{
        state
        | active: Map.delete(state.active, reference),
          maintenance: MapSet.delete(state.maintenance, reference)
      }
  end

  defp launch(state, {key, lane}) do
    if available?(state, lane) and key not in Map.values(state.active) do
      eligible =
        for worker <- state.config.workers,
            status(state, worker) == :ready,
            do: worker.client.worker.id

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          run_work(state.config, key, eligible, lane)
        end)

      maintenance =
        if lane == :maintenance,
          do: MapSet.put(state.maintenance, task.ref),
          else: state.maintenance

      %{state | active: Map.put(state.active, task.ref, key), maintenance: maintenance}
    else
      state
    end
  end

  # One bounded maintenance slot is independent of long-lived execution observers.
  defp available?(state, :maintenance), do: MapSet.size(state.maintenance) < 1

  defp available?(state, :execution),
    do: map_size(state.active) - MapSet.size(state.maintenance) < state.config.max_active

  defp lane(%SmolBox.ManagedMachine{}, _now), do: :maintenance

  defp lane(record, now),
    do: if(Executor.maintenance?(record, now), do: :maintenance, else: :execution)

  defp run_work(config, {:machine, key}, eligible, _lane),
    do: Machines.run(config, key, eligible)

  defp run_work(config, key, eligible, lane), do: Executor.run(config, key, eligible, lane)

  defp status(state, worker) do
    mode = get_in(state.health, [worker.client.worker.id, :admission_mode])

    cond do
      worker.draining or mode == :draining -> :draining
      mode == :unavailable -> :unavailable
      true -> health_status(state, worker)
    end
  end

  defp health_status(state, worker),
    do:
      WorkerHealth.status(
        Map.get(state.health, worker.client.worker.id),
        state.config.clock.monotonic()
      )

  defp scan(config, cursor, machine_cursor, previous, refresh) do
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

    {machines, machine_next} =
      if config.managed_machines do
        case Machines.store(config, :due, [config.clock.now(), machine_cursor, 100]) do
          {:ok, machines, next} -> {machines, next}
          _failed -> {[], nil}
        end
      else
        {[], nil}
      end

    case Session.store(config, :due, [config.clock.now(), cursor, 100]) do
      {:ok, records, next} -> {:scan, health, records, next, machines, machine_next, refresh}
      _failed -> {:scan, health, [], nil, machines, machine_next, refresh}
    end
  end

  defp scan_safely(state, refresh),
    do:
      Session.safe(fn ->
        scan(state.config, state.cursor, state.machine_cursor, state.health, refresh)
      end)

  defp probe(config, worker, previous, refresh) do
    id = worker.client.worker.id

    observation =
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

    Map.put(observation || %{}, :admission_mode, WorkerControls.mode(config, id))
  end
end
