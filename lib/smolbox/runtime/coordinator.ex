defmodule SmolBox.Runtime.Coordinator do
  alias SmolBox.Runtime.Target
  @moduledoc false
  use GenServer

  alias SmolBox.{Execution, Telemetry}

  alias SmolBox.Runtime.{
    Executor,
    KubernetesRecovery,
    KubernetesSupport,
    Machines,
    NativeRecovery,
    NativeSupport,
    Session,
    WorkerControls,
    WorkerHealth
  }

  alias SmolBox.Telemetry.Dispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init({config, parent}) do
    with :ok <- KubernetesSupport.enroll(config),
         {:ok, acquired} <- KubernetesSupport.acquire(config),
         do: init_enrolled(acquired, parent),
         else: ({:error, error} -> {:stop, error})
  end

  defp init_enrolled(config, parent) do
    state = %{
      config: config,
      parent: parent,
      tasks: nil,
      active: %{},
      task_targets: %{},
      native_frozen:
        MapSet.new(
          NativeSupport.targets(config) ++ KubernetesSupport.targets(config),
          &Target.id/1
        ),
      native_holders: %{},
      coordinator: self(),
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

  def handle_call({:native_available, id}, _from, state),
    do: {:reply, not MapSet.member?(state.native_frozen, id), state}

  def handle_call({:native_activity, id}, _from, state),
    do:
      {:reply,
       %{
         ready: not MapSet.member?(state.native_frozen, id),
         held: Map.has_key?(state.native_holders, id)
       }, state}

  def handle_call({:native_acquire_operation, id}, from, state) do
    case handle_call({:native_acquire, id}, from, state) do
      {:reply, :ok, next} ->
        {:reply, {:ok, not MapSet.member?(state.native_frozen, id)}, next}

      result ->
        result
    end
  end

  def handle_call({:native_acquire, id}, {caller, _tag}, state) do
    cond do
      not native_target?(state, id) ->
        {:reply, Session.error(:validation, :reconcile), state}

      Map.has_key?(state.native_holders, id) or native_busy?(state, id) ->
        {:reply, Session.error(:admission_exhausted, :reconcile), state}

      true ->
        holder = {caller, Process.monitor(caller)}

        {:reply, :ok,
         %{
           state
           | native_holders: Map.put(state.native_holders, id, holder),
             native_frozen: MapSet.put(state.native_frozen, id)
         }}
    end
  end

  def handle_call({:native_release, id}, {caller, _tag}, state) do
    case state.native_holders[id] do
      {^caller, monitor} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | native_holders: Map.delete(state.native_holders, id)}}

      _ ->
        {:reply, Session.error(:stale_claim, :reconcile), state}
    end
  end

  def handle_call({:native_quiesce, id}, _from, state) do
    if native_target?(state, id) do
      state = %{state | native_frozen: MapSet.put(state.native_frozen, id)}
      busy = native_busy?(state, id)
      result = if busy, do: Session.error(:admission_exhausted, :reconcile), else: :ok
      {:reply, result, state}
    else
      {:reply, Session.error(:validation, :reconcile), state}
    end
  end

  def handle_call({:native_ready, id}, {caller, _tag}, state) do
    case state.native_holders[id] do
      {^caller, _monitor} ->
        {:reply, :ok, %{state | native_frozen: MapSet.delete(state.native_frozen, id)}}

      _ ->
        {:reply, Session.error(:stale_claim, :reconcile), state}
    end
  end

  # Historical native_* commands serialize both backend authority domains.
  def handle_call({:kubernetes_controller, id, context}, {caller, _tag}, state) do
    case {state.native_holders[id],
          Enum.find(KubernetesSupport.targets(state.config), &(&1.id == id))} do
      {{^caller, _monitor}, target} when not is_nil(target) ->
        config = KubernetesSupport.replace(state.config, target, context)
        {:reply, {:ok, Enum.find(config.workers, &(&1.id == id))}, %{state | config: config}}

      _ ->
        {:reply, Session.error(:stale_claim, :reconcile), state}
    end
  end

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
        id = Target.id(worker)

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
        {:reply, :ok, launch(state, {key, lane, record.worker_id})}
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

    machine_keys =
      Enum.map(machines, &{{:machine, {&1.scope, &1.id}}, :maintenance, &1.worker_id})

    command_keys =
      Enum.map(records, &{Execution.key(&1), lane(&1, state.config.clock.now()), &1.worker_id})

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

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    holders =
      Map.reject(state.native_holders, fn {_id, {_owner, monitor}} -> monitor == reference end)

    {:noreply, forget(%{state | native_holders: holders}, reference)}
  end

  defp native_target?(state, id),
    do: Enum.any?(state.config.workers, &(&1.id == id and &1.kind in [:embedded, :kubernetes]))

  defp native_busy?(state, id),
    do: Enum.any?(state.task_targets, fn {_ref, ids} -> id in ids end)

  defp forget(state, reference) do
    if state.scan == reference,
      do: %{state | scan: nil},
      else: %{
        state
        | active: Map.delete(state.active, reference),
          task_targets: Map.delete(state.task_targets, reference),
          maintenance: MapSet.delete(state.maintenance, reference)
      }
  end

  defp launch(state, {key, lane, assigned}) do
    if available?(state, lane) and key not in Map.values(state.active) and
         not MapSet.member?(state.native_frozen, assigned) do
      eligible =
        for worker <- state.config.workers,
            status(state, worker) == :ready,
            do: Target.id(worker)

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          run_work(state.config, key, eligible, lane)
        end)

      maintenance =
        if lane == :maintenance,
          do: MapSet.put(state.maintenance, task.ref),
          else: state.maintenance

      targets = if assigned, do: [assigned], else: eligible

      %{
        state
        | active: Map.put(state.active, task.ref, key),
          maintenance: maintenance,
          task_targets: Map.put(state.task_targets, task.ref, targets)
      }
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
    mode = get_in(state.health, [Target.id(worker), :admission_mode])

    cond do
      MapSet.member?(state.native_frozen, Target.id(worker)) -> :unavailable
      worker.draining or mode == :draining -> :draining
      mode == :unavailable -> :unavailable
      true -> health_status(state, worker)
    end
  end

  defp health_status(state, worker) do
    if MapSet.member?(state.native_frozen, Target.id(worker)),
      do: :unavailable,
      else:
        WorkerHealth.status(
          Map.get(state.health, Target.id(worker)),
          state.config.clock.monotonic()
        )
  end

  defp scan(config, cursor, machine_cursor, previous, refresh, coordinator) do
    health =
      config.workers
      |> Task.async_stream(&probe(config, &1, previous, refresh, coordinator),
        max_concurrency: 4,
        timeout: config.lease_ms,
        on_timeout: :kill_task
      )
      |> Enum.zip(config.workers)
      |> Map.new(fn
        {{:ok, status}, worker} -> {Target.id(worker), status}
        {_failed, worker} -> {Target.id(worker), nil}
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
        scan(
          state.config,
          state.cursor,
          state.machine_cursor,
          state.health,
          refresh,
          state.coordinator
        )
      end)

  defp probe(config, worker, previous, refresh, coordinator) do
    id = Target.id(worker)

    observation =
      case Session.store(config, :claim_worker, [
             id,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]) do
        {:ok, _lease} ->
          observe_worker(config, worker, previous, refresh, coordinator)

        _failed ->
          nil
      end

    Map.put(observation || %{}, :admission_mode, WorkerControls.mode(config, id))
  end

  defp observe_worker(config, %{kind: :embedded} = worker, previous, _refresh, coordinator),
    do:
      NativeRecovery.observe(
        config,
        worker,
        get_in(previous, [worker.id, :recovery]),
        coordinator
      )

  defp observe_worker(config, %{kind: :kubernetes} = worker, previous, _refresh, coordinator),
    do:
      KubernetesRecovery.observe(
        config,
        worker,
        get_in(previous, [worker.id, :recovery]),
        coordinator
      )

  defp observe_worker(config, worker, previous, refresh, _coordinator),
    do:
      if(refresh,
        do: WorkerHealth.observe(worker, config.clock),
        else: Map.get(previous, Target.id(worker))
      )
end
