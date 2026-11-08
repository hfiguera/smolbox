defmodule SmolBox.Runtime.NativeInspection do
  @moduledoc false
  alias SmolBox.{Backend, Error, Execution, Machine, ManagedMachine}
  alias SmolBox.Embedded.NativeCapture
  alias SmolBox.Runtime.{Session, Target}
  alias SmolBox.Store.BackendAssignments

  # Full authority records can be 16 MiB each. Read exactly one before returning
  # redacted findings; never enumerate the SDK's shared account inventory.
  def page(config, target, options) do
    cursor = Keyword.get(options, :cursor)

    if BackendAssignments.valid_page?(target.id, cursor, 1),
      do: Session.safe(fn -> read(config, target, cursor) end),
      else: Session.error(:validation, :inspect)
  end

  defp read(config, target, cursor) do
    with {:ok, records, next} <-
           Session.store(config, :backend_assignments, [target.id, cursor, 1]),
         true <- BackendAssignments.valid_single_result?(target.id, cursor, records, next) do
      target = if records == [], do: target, else: Target.pin(target)

      {:ok,
       %{
         worker_id: target.id,
         backend_kind: :embedded,
         inventory_scope: :assigned_records,
         checked_at_ms: config.clock.now(),
         foreign_count: nil,
         candidates: Enum.map(records, &finding(target, &1)),
         next_cursor: next
       }}
    else
      {:error, _} = error -> error
      _invalid -> Session.error(:store, :backend_assignments)
    end
  end

  defp finding(target, record) do
    reference = Target.connection(target, record)
    {state, status} = observe(reference, record)

    %{
      machine_name: record.machine_name,
      observed_state: state,
      status: status,
      record_version: record.version
    }
    |> link(record)
  end

  defp observe(_reference, %{created_machine: nil}), do: {:unverified, :unverified}

  defp observe(reference, record) do
    reference = Backend.bounded(reference, timeout_ms: 1000, max_response_bytes: 16_384)

    case Backend.inspect_machine(reference, record.machine_name) do
      {:ok, %Machine{} = machine} -> {machine.state, ownership(record, machine)}
      {:error, %Error{category: :not_found}} -> {:missing, :absent}
      {:error, %Error{category: :identity_conflict}} -> {:unknown, :conflict}
      _unavailable -> {:unknown, :unavailable}
    end
  end

  defp ownership(record, observed) do
    cond do
      not NativeCapture.observation_valid?(record, observed) -> :conflict
      released?(record) -> :cleanup_conflict
      true -> :owned
    end
  end

  defp released?(%Execution{managed_machine: machine}) when not is_nil(machine), do: false
  defp released?(record), do: record.reservation == nil

  defp link(finding, %Execution{} = record),
    do: Map.put(finding, :execution, Execution.key(record))

  defp link(finding, %ManagedMachine{} = record),
    do: Map.put(finding, :managed_machine, ManagedMachine.key(record))
end
