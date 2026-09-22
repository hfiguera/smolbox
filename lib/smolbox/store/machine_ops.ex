defmodule SmolBox.Store.MachineOps do
  @moduledoc """
  Pure retained-machine transactions. Adapters must lock the machine, execution,
  assignment index, and shared worker capacity together before using these checks.
  """
  alias SmolBox.{Error, Execution, ManagedMachine, Validation}
  alias SmolBox.Store.RecordOps

  def initial(record) do
    with :ok <- ManagedMachine.validate(record),
         {:ok, expected} <-
           ManagedMachine.new(record.spec, record.fingerprint, record.accepted_at_ms),
         true <- expected == record do
      :ok
    else
      _invalid -> error(:validation)
    end
  end

  def reserve(record, worker, name, lease, capacity, usage, now) do
    needed = RecordOps.resources(record)

    with true <- record.state == :accepted and record.worker_id == nil,
         true <- Validation.identifier?(worker) and SmolBox.MachineSpec.valid_name?(name),
         true <- is_map(lease) and lease.owner == record.claim_owner and lease.until_ms > now,
         true <- Enum.sort(Map.keys(capacity)) == Enum.sort(Map.keys(needed)),
         true <-
           Enum.all?(needed, fn {key, value} ->
             Validation.integer?(capacity[key], 1, 1_048_576) and
               usage[key] + value <= capacity[key]
           end) do
      ManagedMachine.update(
        record,
        %{
          worker_id: worker,
          worker_generation: lease.generation,
          machine_name: name,
          reservation: needed,
          reserved_ports: Enum.map(record.spec.ports, & &1.host),
          state: :creating
        },
        now
      )
    else
      _unavailable -> error(:admission_exhausted)
    end
  end

  def request(record, action, version, now) when action in [:start, :stop, :delete] do
    cond do
      not Validation.integer?(version, 1, 9_007_199_254_740_991) ->
        error(:validation)

      record.last_request == {action, version} ->
        {:ok, record}

      record.version != version ->
        error(:stale_version)

      unassigned_delete?(record, action) ->
        ManagedMachine.update(
          record,
          %{state: :deleted, operation: nil, phase: nil, last_request: {action, version}},
          now
        )

      not ManagedMachine.idle?(record) ->
        error(:admission_exhausted)

      record.state == :deleted ->
        error(:identity_conflict)

      record.state not in [:created, :running, :stopped] ->
        error(:unknown)

      true ->
        state = %{start: :starting, stop: :stopping, delete: :deleting}[action]

        ManagedMachine.update(
          record,
          %{
            operation: action,
            phase: :pending,
            state: state,
            last_request: {action, version},
            operation_deadline_ms: nil,
            next_due_at_ms: now
          },
          now
        )
    end
  end

  def request(_record, _action, _version, _now), do: error(:validation)

  defp unassigned_delete?(%{state: state, worker_id: nil}, :delete)
       when state in [:accepted, :conflict], do: true

  defp unassigned_delete?(_record, _action), do: false

  def attach(machine, execution, now) do
    with :ok <- RecordOps.initial(execution),
         true <- machine.state == :running and ManagedMachine.idle?(machine),
         true <-
           execution.scope == machine.scope and execution.spec.profile == machine.spec.profile and
             execution.spec.artifact == machine.spec.artifact,
         command = %{
           execution
           | managed_machine: ManagedMachine.key(machine),
             worker_id: machine.worker_id,
             worker_generation: machine.worker_generation,
             machine_name: machine.machine_name,
             created_machine: machine.created_machine
         },
         :ok <- Execution.validate(command),
         {:ok, machine} <-
           ManagedMachine.update(machine, %{active_execution: Execution.key(command)}, now) do
      {:ok, machine, command}
    else
      {:error, _error} = error -> error
      _busy -> error(:admission_exhausted)
    end
  end

  def finish(machine, execution, now) do
    with true <- machine.active_execution == Execution.key(execution),
         true <- Execution.terminal?(execution) or execution.state == :unknown do
      finish_changes(machine, execution, now, safe_completion?(execution))
    else
      _invalid -> error(:stale_claim)
    end
  end

  defp finish_changes(machine, execution, now, safe?) do
    command_changes =
      if safe?, do: [cleanup: :complete], else: [cleanup: :failed, next_due_at_ms: now + 60_000]

    machine_changes =
      if safe?, do: %{active_execution: nil, next_due_at_ms: now}, else: %{state: :unknown}

    with {:ok, command} <- Execution.transition(execution, command_changes, now),
         {:ok, machine} <- ManagedMachine.update(machine, machine_changes, now),
         do: {:ok, machine, command}
  end

  def resolve(machine, command, :absent, now) do
    with true <- machine.state in [:unknown, :missing, :conflict],
         {:ok, command} <- resolve_command(command, now),
         {:ok, machine} <-
           ManagedMachine.update(
             machine,
             %{
               state: :deleted,
               reservation: nil,
               reserved_ports: [],
               operation: nil,
               phase: nil,
               active_execution: nil,
               operation_deadline_ms: nil,
               resolved_at_ms: now,
               absence_at_ms: machine.absence_at_ms || now
             },
             now
           ) do
      {:ok, machine, command}
    else
      {:error, _error} = error -> error
      _invalid -> error(:validation)
    end
  end

  def resolve(machine, command, observed, now) do
    with true <- machine.state in [:unknown, :missing, :conflict],
         true <- machine.created_machine != nil,
         true <- observed.state in [:created, :stopped],
         true <- SmolBox.Machine.same_incarnation?(machine.created_machine, observed),
         {:ok, command} <- resolve_command(command, now),
         {:ok, machine} <-
           ManagedMachine.update(
             machine,
             %{
               state: observed.state,
               observed_machine: observed,
               operation: nil,
               phase: nil,
               active_execution: nil,
               operation_deadline_ms: nil,
               resolved_at_ms: now,
               next_due_at_ms: now + 60_000
             },
             now
           ) do
      {:ok, machine, command}
    else
      {:error, _error} = error -> error
      _invalid -> error(:identity_conflict)
    end
  end

  defp resolve_command(nil, _now), do: {:ok, nil}

  defp resolve_command(command, now) do
    if Execution.terminal?(command) or command.state == :unknown,
      do: Execution.transition(command, [cleanup: :complete], now),
      else: error(:admission_exhausted)
  end

  defp safe_completion?(%{state: state}) when state in [:completed, :launched], do: true

  defp safe_completion?(%{state: state, spec: %{inputs: []}})
       when state in [:cancelled, :expired], do: true

  defp safe_completion?(_record), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
