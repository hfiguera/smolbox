defmodule SmolBox.DurableHost.MachineStore do
  @moduledoc false
  alias SmolBox.DurableHost.{Database, MachineIndex}
  alias SmolBox.{Error, Execution, ManagedMachine, Validation}
  alias SmolBox.Store.{MachineOps, RecordOps}

  # Every entry runs under Store's partition transaction, including command
  # acceptance/completion and capacity accounting shared with disposable work.
  def run(context, :fetch, [key]), do: Database.read(context, key, :machine)

  def run(context, :accept, [record, max_pending]) do
    with :ok <- MachineOps.initial(record),
         true <- Validation.integer?(max_pending, 1, 10_000) do
      case Database.read(context, ManagedMachine.key(record), :machine) do
        {:ok, %{fingerprint: fingerprint} = existing} when fingerprint == record.fingerprint ->
          {:ok, existing}

        {:ok, _conflict} ->
          error(:identity_conflict)

        {:error, %Error{category: :not_found}} ->
          insert_machine(context, record, max_pending)

        error ->
          error
      end
    else
      _invalid -> error(:validation)
    end
  end

  def run(context, :list, [scope, cursor, limit]) do
    if Validation.identifier?(scope) and (cursor == nil or Validation.identifier?(cursor)) and
         Validation.integer?(limit, 1, 100),
       do: Database.machine_page(context, scope, cursor, limit),
       else: error(:validation)
  end

  def run(context, :due, [now, cursor, limit]) do
    if Validation.timestamp?(now) and valid_cursor?(cursor) and Validation.integer?(limit, 1, 100),
      do: Database.due(context, now, cursor, limit, :machine),
      else: error(:validation)
  end

  def run(context, :claim_version, [key, version, owner, now, ttl]) do
    with {:ok, record} <- Database.read(context, key, :machine) do
      if record.version == version,
        do: run(context, :claim, [key, owner, now, ttl]),
        else: error(:stale_version)
    end
  end

  def run(context, :claim, [key, owner, now, ttl]) do
    with {:ok, record} <- Database.read(context, key, :machine),
         {:ok, next} <-
           RecordOps.claim(
             record,
             Database.worker_lease(context, record.worker_id),
             owner,
             now,
             ttl
           ),
         do: persist(context, next)
  end

  def run(context, :write, [key, guard, changes, now]) do
    with {:ok, record} <- guarded(context, key, guard, now),
         {:ok, next} <- ManagedMachine.transition(record, changes, now),
         do: persist(context, next)
  end

  def run(context, :reserve, [key, guard, {worker, name, capacity}, now]) do
    with {:ok, record} <- guarded(context, key, guard, now),
         {:ok, used} <- Database.usage(context, worker),
         {:ok, next} <-
           MachineOps.reserve(
             record,
             worker,
             name,
             Database.worker_lease(context, worker),
             capacity,
             used,
             now
           ),
         do: persist(context, next)
  end

  def run(context, :request, [key, action, version, now]) do
    with {:ok, record} <- Database.read(context, key, :machine),
         {:ok, next} <- MachineOps.request(record, action, version, now),
         do: persist(context, next)
  end

  def run(context, :submit, [key, execution, max_pending, now]) do
    with :ok <- RecordOps.initial(execution),
         true <- Validation.integer?(max_pending, 1, 10_000) do
      case Database.read(context, Execution.key(execution)) do
        {:ok, existing} ->
          duplicate_command(existing, execution, key)

        {:error, %Error{category: :not_found}} ->
          attach(context, key, execution, max_pending, now)

        error ->
          error
      end
    else
      _invalid -> error(:validation)
    end
  end

  def run(context, :finish, [key, guard, now]) do
    with {:ok, execution} <- Database.read(context, key),
         :ok <-
           RecordOps.guard(
             execution,
             guard,
             Database.worker_lease(context, execution.worker_id),
             now
           ),
         {:ok, machine} <- Database.read(context, execution.managed_machine, :machine),
         {:ok, machine, execution} <- MachineOps.finish(machine, execution, now),
         {:ok, _machine} <- persist(context, machine),
         do: Database.write(context, execution)
  end

  def run(context, :resolve, [key, guard, observed, now]) do
    with {:ok, machine} <- guarded(context, key, guard, now),
         {:ok, command} <- active_record(context, machine),
         {:ok, machine, command} <- MachineOps.resolve(machine, command, observed, now),
         :ok <- persist_optional(context, command),
         do: persist(context, machine)
  end

  def run(_context, _operation, _arguments), do: error(:validation)

  def active?(context, %{managed_machine: key} = record) when not is_nil(key) do
    with {:ok, machine} <- Database.read(context, key, :machine) do
      if machine.active_execution == Execution.key(record), do: :ok, else: error(:stale_claim)
    end
  end

  def active?(_context, _record), do: :ok

  defp duplicate_command(existing, execution, key) do
    if existing.fingerprint == execution.fingerprint and existing.managed_machine == key,
      do: {:ok, existing},
      else: error(:identity_conflict)
  end

  defp insert_machine(context, record, max_pending) do
    if Database.pending_count(context, :machine) < max_pending,
      do: persist(context, record),
      else: error(:admission_exhausted)
  end

  defp attach(context, key, execution, max_pending, now) do
    if Database.pending_count(context) < max_pending do
      with {:ok, machine} <- Database.read(context, key, :machine),
           {:ok, machine, execution} <- MachineOps.attach(machine, execution, now),
           {:ok, _machine} <- persist(context, machine),
           :ok <- MachineIndex.remember(context, execution),
           do: Database.write(context, execution)
    else
      error(:admission_exhausted)
    end
  end

  defp guarded(context, key, guard, now) do
    with {:ok, record} <- Database.read(context, key, :machine),
         :ok <-
           RecordOps.guard(record, guard, Database.worker_lease(context, record.worker_id), now),
         do: {:ok, record}
  end

  defp persist(context, record) do
    with :ok <- exclusive_assignment(context, record),
         {:ok, record} <- Database.write(context, record) do
      Database.query(
        context,
        "UPDATE smolbox_managed_machines SET machine_name=$4 WHERE partition=$1 AND scope=$2 AND execution_id=$3",
        [context.partition, record.scope, record.id, record.machine_name]
      )

      {:ok, record}
    end
  end

  defp exclusive_assignment(_context, %{worker_id: nil}), do: :ok

  defp exclusive_assignment(context, record) do
    case Database.query(
           context,
           "SELECT 1 FROM smolbox_machine_identities WHERE partition=$1 AND worker_id=$2 AND machine_name=$3",
           [context.partition, record.worker_id, record.machine_name]
         ).rows do
      [] -> :ok
      _conflict -> error(:identity_conflict)
    end
  end

  defp active_record(_context, %{active_execution: nil}), do: {:ok, nil}
  defp active_record(context, machine), do: Database.read(context, machine.active_execution)
  defp persist_optional(_context, nil), do: :ok

  defp persist_optional(context, command) do
    with {:ok, _command} <- Database.write(context, command), do: :ok
  end

  defp valid_cursor?(nil), do: true

  defp valid_cursor?({now, scope, id}),
    do:
      Validation.timestamp?(now) and Validation.identifier?(scope) and Validation.identifier?(id)

  defp valid_cursor?(_cursor), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
