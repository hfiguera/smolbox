defmodule SmolBox.Runtime.Machines do
  @moduledoc false
  alias SmolBox.{Client, Error, Identity, Machine, ManagedMachine}
  alias SmolBox.Runtime.ExecutionSupport
  alias SmolBox.Runtime.{Session, WorkerConfig, WorkerHealth}

  def store(config, operation, arguments),
    do: Session.store(config, :machine, [operation, arguments])

  def run(config, key, eligible) do
    Session.safe(fn ->
      with {:ok, record} <- claim(config, key),
           :ok <- port_support(config, record.spec.ports),
           :ok <- ExecutionSupport.check(config, record.spec) do
        route(config, record, eligible)
      end
    end)
  end

  def port_support(_config, []), do: :ok

  def port_support(config, _ports) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_ports: 1}} -> :ok
      {:ok, _unsupported} -> Session.error(:unsupported_capability, :machine)
      error -> error
    end
  end

  def claim(config, key),
    do: store(config, :claim, [key, config.owner, config.clock.now(), config.lease_ms])

  def write(config, record, changes),
    do:
      store(config, :write, [
        ManagedMachine.key(record),
        Session.guard(record),
        changes,
        config.clock.now()
      ])

  defp route(config, %{state: :accepted} = record, eligible),
    do: reserve(config, record, eligible)

  defp route(config, %{state: :conflict, worker_id: nil} = record, _eligible),
    do: write(config, record, next_due_at_ms: config.clock.now() + 60_000)

  defp route(_config, %{active_execution: key} = record, _eligible) when not is_nil(key),
    do: {:ok, record}

  defp route(_config, %{state: :deleted} = record, _eligible), do: {:ok, record}
  defp route(config, %{phase: :pending} = record, _eligible), do: dispatch(config, record)
  defp route(config, record, _eligible), do: observe(config, record)

  defp reserve(config, record, eligible) do
    workers =
      Enum.filter(
        config.workers,
        &(&1.client.worker.id in eligible and WorkerConfig.supports?(&1, record.spec))
      )

    result =
      Enum.reduce_while(workers, {:ok, record}, fn worker, _previous ->
        with %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
             {:ok, current} <- claim(config, ManagedMachine.key(record)),
             {:ok, name} <- Identity.machine_name(config.namespace),
             {:ok, reserved} <-
               store(config, :reserve, [
                 ManagedMachine.key(record),
                 Session.guard(current),
                 {worker.client.worker.id, name, worker.capacity},
                 config.clock.now()
               ]) do
          {:halt, dispatch(config, reserved)}
        else
          {:error, %Error{category: :admission_exhausted}} ->
            {:cont, {:ok, record}}

          {:error, %Error{category: :port_conflict} = error} ->
            {:halt,
             fresh_write(config, record,
               state: :conflict,
               operation: nil,
               phase: nil,
               last_error: error,
               next_due_at_ms: config.clock.now() + 60_000
             )}

          {:error, _error} = error ->
            {:halt, error}

          _unready ->
            {:cont, {:ok, record}}
        end
      end)

    defer_admission(config, result)
  end

  defp defer_admission(config, {:ok, %{state: :accepted} = record}),
    do: fresh_write(config, record, next_due_at_ms: config.clock.now() + 1000)

  defp defer_admission(_config, result), do: result

  defp dispatch(config, record) do
    with {:ok, worker} <- worker(config, record),
         true <-
           record.operation in [:stop, :delete] or WorkerConfig.supports?(worker, record.spec),
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         :ok <- verify_before(config, record, worker),
         {:ok, current} <- claim(config, ManagedMachine.key(record)),
         true <- current.phase == :pending and current.active_execution == nil,
         {:ok, intent} <-
           write(config, current,
             phase: :dispatching,
             operation_deadline_ms: config.clock.now() + record.spec.profile.preparation_ms
           ) do
      result = io(config, intent, fn -> mutate(worker, intent) end)
      complete_response(config, intent, result)
    else
      {:error, error} ->
        failed_observation(config, record, error)

      _unready ->
        failed_observation(config, record, %Error{
          category: :unsupported_capability,
          operation: :worker
        })
    end
  end

  defp verify_before(_config, %{operation: :create, created_machine: nil}, _worker), do: :ok

  defp verify_before(config, record, worker) do
    with {:ok, observed} <-
           io(config, record, fn -> Client.inspect_machine(worker.client, record.machine_name) end),
         true <-
           record.created_machine != nil and
             Machine.same_incarnation?(record.created_machine, observed) do
      :ok
    else
      false -> Session.error(:identity_conflict, :inspect)
      error -> error
    end
  end

  defp mutate(worker, %{operation: :create} = record) do
    with {:ok, spec} <- WorkerConfig.machine_spec(worker, record.spec, record.machine_name),
         do: Client.create(worker.client, spec)
  end

  defp mutate(worker, record),
    do: apply(Client, record.operation, [worker.client, record.machine_name])

  defp complete_response(config, record, {:ok, %Machine{} = observed}) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         creation = current.created_machine || if(current.operation == :create, do: observed),
         true <- creation != nil and Machine.same_incarnation?(creation, observed),
         {:ok, saved} <-
           write(config, current, created_machine: creation, observed_machine: observed) do
      confirm(config, saved)
    else
      false ->
        failed_observation(config, record, %Error{
          category: :identity_conflict,
          operation: :inspect
        })

      error ->
        error
    end
  end

  defp complete_response(config, record, :ok), do: confirm(config, record)
  defp complete_response(config, record, {:error, error}), do: uncertain(config, record, error)

  defp complete_response(config, record, _invalid),
    do: uncertain(config, record, %Error{category: :protocol, operation: :machine})

  # Only the process receiving the mutation response may complete a start/stop.
  # Recovery cannot distinguish an observed state from a delayed old request.
  defp confirm(config, record) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         {:ok, worker} <- worker(config, current) do
      case io(config, current, fn ->
             Client.inspect_machine(worker.client, current.machine_name)
           end) do
        {:ok, observed} ->
          confirm_present(config, current, observed)

        {:error, %Error{category: :not_found}} when current.operation == :delete ->
          deleted(config, current)

        {:error, error} ->
          uncertain(config, current, error)
      end
    end
  end

  defp confirm_present(config, record, observed) do
    expected = %{start: :running, stop: :stopped, create: observed.state}[record.operation]

    if record.created_machine != nil and
         Machine.same_incarnation?(record.created_machine, observed) and
         observed.state == expected do
      fresh_write(config, record,
        state: observed.state,
        observed_machine: observed,
        operation: nil,
        phase: nil,
        operation_deadline_ms: nil,
        last_error: nil,
        next_due_at_ms: config.clock.now() + 60_000
      )
    else
      uncertain(config, record, %Error{category: :unknown, operation: :inspect})
    end
  end

  defp observe(config, record) do
    record = %{record | operation_deadline_ms: nil}

    with {:ok, worker} <- worker(config, record) do
      case io(config, record, fn -> Client.inspect_machine(worker.client, record.machine_name) end) do
        {:ok, observed} -> observe_present(config, record, observed)
        {:error, %Error{category: :not_found}} -> observe_absent(config, record)
        {:error, error} -> failed_observation(config, record, error)
      end
    end
  end

  defp observe_present(config, record, observed) do
    cond do
      record.created_machine == nil ->
        uncertain(config, record, %Error{category: :unknown, operation: :create})

      not Machine.same_incarnation?(record.created_machine, observed) ->
        failed_observation(config, record, %Error{
          category: :identity_conflict,
          operation: :inspect
        })

      record.phase != nil or record.state in [:unknown, :missing, :conflict] ->
        fresh_write(config, record,
          state: :unknown,
          observed_machine: observed,
          phase: if(record.operation, do: :uncertain),
          next_due_at_ms: config.clock.now() + 60_000
        )

      record.state != observed.state ->
        uncertain(config, record, %Error{category: :unknown, operation: :inspect})

      true ->
        fresh_write(config, record,
          state: observed.state,
          observed_machine: observed,
          next_due_at_ms: config.clock.now() + 60_000
        )
    end
  end

  defp observe_absent(config, %{operation: :delete, created_machine: creation} = record)
       when not is_nil(creation), do: deleted(config, record)

  defp observe_absent(config, record),
    do: fresh_write(config, record, state: :missing, next_due_at_ms: config.clock.now() + 60_000)

  defp deleted(config, record),
    do:
      fresh_write(config, record,
        state: :deleted,
        operation: nil,
        phase: nil,
        absence_at_ms: config.clock.now(),
        operation_deadline_ms: nil
      )

  defp uncertain(config, record, error),
    do:
      fresh_write(config, record,
        state: :unknown,
        phase: if(record.operation, do: :uncertain),
        last_error: %{error | evidence: :unknown},
        next_due_at_ms: config.clock.now() + 60_000
      )

  defp failed_observation(config, record, %Error{category: :identity_conflict} = error),
    do:
      fresh_write(config, record,
        state: :conflict,
        last_error: error,
        next_due_at_ms: config.clock.now() + 60_000
      )

  defp failed_observation(config, record, %Error{category: :not_found}),
    do: observe_absent(config, record)

  defp failed_observation(config, record, error),
    do:
      fresh_write(config, record, last_error: error, next_due_at_ms: config.clock.now() + 60_000)

  defp fresh_write(config, record, changes) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         # I/O may have overlapped a new lifecycle request or command. Renewed
         # claims do not authorize applying the old observation to newer work.
         fields = [:state, :operation, :phase, :last_request, :active_execution],
         true <- Map.take(current, fields) == Map.take(record, fields) do
      write(config, current, changes)
    else
      false -> Session.error(:stale_version, :machine)
      error -> error
    end
  end

  def worker(config, record) do
    case Enum.find(config.workers, &(&1.client.worker.id == record.worker_id)) do
      nil -> Session.error(:unsupported_capability, :worker)
      worker -> {:ok, worker}
    end
  end

  def io(config, record, function) do
    task = Task.async(fn -> Session.safe(function) end)

    deadline =
      record.operation_deadline_ms || config.clock.now() + record.spec.profile.preparation_ms

    try do
      await_io(config, record, task, deadline)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_io(config, record, task, deadline) do
    budget = deadline - config.clock.now()

    if budget <= 0 do
      Session.error(:expired, :runtime)
    else
      case Task.yield(task, min(budget, config.poll_ms)) do
        {:ok, result} ->
          result

        nil ->
          renew_io(config, record, task, deadline)

        _lost ->
          Session.error(:unknown, :runtime)
      end
    end
  end

  defp renew_io(config, record, task, deadline) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         do: await_io(config, current, task, deadline)
  end
end
