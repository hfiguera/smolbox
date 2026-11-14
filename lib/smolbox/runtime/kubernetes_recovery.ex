defmodule SmolBox.Runtime.KubernetesRecovery do
  @moduledoc false
  alias SmolBox.{Backend, Error, Execution, Machine}

  alias SmolBox.Kubernetes.{
    Assignment,
    Config,
    Health,
    LabController,
    Operation,
    Pod,
    PodTemplate
  }

  alias SmolBox.Runtime.{
    Executor,
    NativeAuthority,
    Session,
    Target,
    WorkerHealth
  }

  alias SmolBox.Store.BackendAssignments

  def observe(config, target, previous, coordinator) do
    case Session.safe(fn -> recover(config, target, previous, coordinator) end) do
      {:ok, observation} -> observation
      {:error, %Error{} = error} -> report(config, previous, error)
      _ -> report(config, previous, nil)
    end
  end

  defp recover(config, target, previous, coordinator) do
    context = target.kubernetes_config.controller_guard

    with true <- context != nil and context.owner == config.owner,
         :ok <-
           LabController.check(
             Config.binding(target.kubernetes_config),
             target.connection.budget,
             context
           ) do
      proceed(config, target, state(config, context, previous), coordinator)
    else
      _ -> Session.error(:identity_conflict, :reconcile)
    end
  end

  defp proceed(config, target, state, coordinator) do
    activity = NativeAuthority.activity(coordinator, target.id)

    if state.phase == :ready and activity.ready,
      do: {:ok, WorkerHealth.observe(target, config.clock) |> Map.put(:recovery, state)},
      else:
        NativeAuthority.run(coordinator, target.id, fn ->
          scan(config, target, restart(state), coordinator)
        end)
  end

  defp state(config, context, previous) do
    channel = {context.domain_id, config.owner}

    if previous && previous.channel == channel,
      do: previous,
      else: %{channel: channel, phase: :scanning, cursor: nil, records: %{}}
  end

  defp restart(%{phase: :ready} = state),
    do: %{state | phase: :scanning, cursor: nil, records: %{}}

  defp restart(state), do: state

  defp scan(config, target, state, coordinator) do
    with :ok <- GenServer.call(coordinator, {:native_quiesce, target.id}),
         {:ok, records, cursor} <-
           Session.store(config, :backend_assignments, [target.id, state.cursor, 1]),
         true <- BackendAssignments.valid_single_result?(target.id, state.cursor, records, cursor),
         {:ok, corpus} <- page(config, target, state.records, records) do
      next = %{state | cursor: cursor, records: corpus}

      if cursor == nil,
        do: finalize(config, target, next, coordinator),
        else: {:ok, report(config, next, nil)}
    else
      {:error, _} = error -> error
      _ -> Session.error(:store, :reconcile)
    end
  end

  defp page(_config, _target, corpus, []), do: {:ok, corpus}

  defp page(config, target, corpus, [%Execution{} = record]) do
    context = target.kubernetes_config.controller_guard

    with true <- context.enrolled and record.claim_owner in context.known_owners,
         true <- Assignment.approved?(record.backend_assignment, target.kubernetes_config, record),
         true <- map_size(corpus) < 1024 and not Map.has_key?(corpus, record.machine_name),
         {:ok, current} <- classify(config, target, record) do
      {:ok, Map.put(corpus, record.machine_name, current)}
    else
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :reconcile)
    end
  end

  defp page(_, _, _, _), do: Session.error(:identity_conflict, :reconcile)

  defp classify(config, target, %{state: :ready} = record) do
    session = Session.new(config, record)

    if record.cancel_requested_at_ms != nil or
         Session.remaining(session, record, :preparation) <= 0 do
      with {:ok, retired} <- retire_ready(session), do: reconcile(config, retired)
    else
      inspect_ready(target, record)
    end
  end

  defp classify(config, _target, record), do: reconcile(config, record)

  # Persist a terminal state before reusing Executor: recovery must never enter
  # its ready-command dispatch route, even if the clock changes after expiry.
  defp retire_ready(session) do
    with {:ok, current} <- Session.claim(session) do
      if current.state == :ready,
        do:
          Session.write(session, current,
            state: if(current.cancel_requested_at_ms != nil, do: :cancelled, else: :failed),
            last_error: %Error{category: :expired, operation: :runtime}
          ),
        else: {:ok, current}
    end
  end

  defp inspect_ready(target, record) do
    with {:ok, %Machine{} = machine} <-
           Backend.inspect_machine(
             Backend.bounded(Target.connection(target, record), timeout_ms: 5000),
             record.machine_name
           ),
         true <- Machine.same_incarnation?(record.created_machine, machine),
         do: {:ok, record},
         else: (_ -> Session.error(:identity_conflict, :reconcile))
  end

  defp reconcile(config, record) do
    with {:ok, current} <- Executor.run(config, Execution.key(record), []),
         true <- current.cleanup == :complete and current.reservation == nil,
         do: {:ok, current},
         else: (
           {:error, _} = error -> error
           _ -> Session.error(:cleanup, :reconcile)
         )
  end

  defp finalize(config, target, state, coordinator) do
    kube = target.kubernetes_config

    with {:ok, records} <- fresh_ready(config, target, state.records),
         {:ok, operation} <- Operation.new(kube, %{kube.budget | timeout_ms: 5000}, :inspect),
         {:ok, inventory} <- Pod.inventory(operation),
         true <- inventory?(inventory, records),
         {:ok, node} <- Operation.run(operation, fn _sent -> Health.node_status(operation) end),
         true <- node.idle or Enum.any?(records, fn {_, r} -> r.state == :ready end),
         {:ok, context} <-
           LabController.activate(Config.binding(kube), kube.budget, kube.controller_guard),
         {:ok, activated} <-
           GenServer.call(coordinator, {:kubernetes_controller, target.id, context}),
         :ok <- GenServer.call(coordinator, {:native_ready, target.id}) do
      {:ok,
       WorkerHealth.observe(activated, config.clock)
       |> Map.put(:recovery, %{state | phase: :ready, records: records})}
    else
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :reconcile)
    end
  end

  defp fresh_ready(config, target, records) do
    Enum.reduce_while(records, {:ok, records}, fn
      {name, %{state: :ready} = record}, {:ok, corpus} ->
        # Cancellation can arrive after an earlier page was observed. Re-read
        # durable intent before the final inventory/activation checks.
        with {:ok, %Execution{} = current} <-
               Session.store(config, :fetch, [Execution.key(record)]),
             true <- current.backend_assignment == record.backend_assignment,
             {:ok, next} <- page(config, target, Map.delete(corpus, name), [current]) do
          {:cont, {:ok, next}}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, Session.error(:identity_conflict, :reconcile)}
        end

      _, result ->
        {:cont, result}
    end)
  end

  defp inventory?(inventory, records) do
    ready =
      Map.filter(records, fn {_, record} ->
        record.state == :ready and record.reservation != nil
      end)

    length(inventory) == map_size(ready) and Enum.all?(inventory, &owned?(&1, ready))
  end

  defp owned?(pod, ready) do
    case ready[get_in(pod, ["metadata", "name"])] do
      nil ->
        false

      record ->
        get_in(pod, ["metadata", "uid"]) == record.backend_receipt.pod_uid and
          PodTemplate.matches?(pod, record.backend_assignment)
    end
  end

  defp report(config, state, error),
    do: %{
      status: :unavailable,
      health: nil,
      checked_at_ms: config.clock.now(),
      checked_monotonic: config.clock.monotonic(),
      recovery: state,
      recovery_error: error
    }
end
