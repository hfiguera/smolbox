defmodule SmolBox.WorkerMaintenance do
  @moduledoc """
  A bounded, store-consistent page of a worker's remaining managed resources.

  `records` contains redacted assignments needing attention, including retained
  machines, unfinished execution cleanup and retained capture/export/branch
  resources. Completed clean execution history is omitted. Follow `next_cursor`
  to inspect subsequent pages; pages taken at different times are not one snapshot.

  `reserved` is total worker accounting, not just this page. `assessment` is
  `:blocked` unless the first page is empty, accounting is zero and admission is
  draining. Even then it is only `:operator_quiescence_required`: other controllers,
  delayed HTTP requests, background processes and unmanaged machines require host
  verification. This API never certifies that shutdown is safe.
  """
  alias SmolBox.{Execution, ManagedMachine, WorkerControl}
  alias SmolBox.Store.RecordOps

  @enforce_keys [
    :control,
    :reserved,
    :records,
    :cursor,
    :next_cursor,
    :checked_at_ms,
    :assessment
  ]
  defstruct @enforce_keys
  @type cursor :: {0 | 1 | 2, String.t(), String.t()} | nil
  @type entry :: %{
          kind: :execution | :machine | :volume,
          scope: String.t(),
          id: String.t(),
          machine_name: String.t() | nil,
          state: atom(),
          operation: atom() | nil,
          active_execution: Execution.key() | nil,
          evidence: atom() | nil,
          cleanup: atom() | nil,
          reserved: SmolBox.Store.resources()
        }
  @type t :: %__MODULE__{
          control: WorkerControl.t(),
          reserved: SmolBox.Store.resources(),
          records: [entry()],
          cursor: cursor(),
          next_cursor: cursor(),
          checked_at_ms: non_neg_integer(),
          assessment: :blocked | :operator_quiescence_required
        }

  @doc false
  def page(control, reserved, records, cursor, limit, now) do
    selected =
      records
      |> Enum.filter(&relevant?/1)
      |> Enum.sort_by(&position/1)
      |> Enum.filter(&(cursor == nil or position(&1) > cursor))
      |> Enum.take(limit + 1)

    page = Enum.take(selected, limit)
    next = if length(selected) > limit, do: position(List.last(page))

    %__MODULE__{
      control: control,
      reserved: reserved,
      records: Enum.map(page, &entry/1),
      cursor: cursor,
      next_cursor: next,
      checked_at_ms: now,
      assessment: assessment(control, reserved, page, cursor, next)
    }
  end

  defp assessment(%{mode: :draining}, reserved, [], nil, nil) do
    if reserved == RecordOps.empty_usage(), do: :operator_quiescence_required, else: :blocked
  end

  defp assessment(_, _, _, _, _), do: :blocked

  @doc false
  def relevant?(%SmolBox.Volume{} = v), do: v.state != :deleted

  def relevant?(%ManagedMachine{} = record),
    do: record.state != :deleted or resources?(record)

  def relevant?(%Execution{} = record),
    do: RecordOps.needs_work?(record) or resources?(record)

  defp resources?(record),
    do: Enum.any?(RecordOps.accounted_resources(record), fn {_, n} -> n > 0 end)

  @doc false
  def position(%SmolBox.Volume{} = v), do: {2, v.scope, v.id}
  def position(%ManagedMachine{} = record), do: {1, record.scope, record.id}
  def position(%Execution{} = record), do: {0, record.scope, record.id}

  defp kind(%SmolBox.Volume{}), do: :volume
  defp kind(%ManagedMachine{}), do: :machine
  defp kind(%Execution{}), do: :execution

  defp entry(record) do
    %{
      kind: kind(record),
      scope: record.scope,
      id: record.id,
      machine_name: Map.get(record, :machine_name),
      state: record.state,
      operation: Map.get(record, :operation),
      active_execution: Map.get(record, :active_execution),
      evidence: Map.get(record, :evidence),
      cleanup: Map.get(record, :cleanup),
      reserved: RecordOps.accounted_resources(record)
    }
  end

  @doc false
  def valid_page?(worker, cursor, limit) do
    SmolBox.Validation.identifier?(worker) and SmolBox.Validation.integer?(limit, 1, 100) and
      valid_cursor?(cursor)
  end

  defp valid_cursor?(nil), do: true

  defp valid_cursor?({kind, scope, id}),
    do:
      kind in [0, 1, 2] and
        SmolBox.Validation.identifier?(scope) and SmolBox.Validation.identifier?(id)

  defp valid_cursor?(_), do: false
end
