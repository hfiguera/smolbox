defmodule SmolBox.Store.BackendAssignments do
  @moduledoc false
  alias SmolBox.{Error, Execution, ManagedMachine, Volume, WorkerMaintenance}

  def valid_page?(worker, cursor, limit),
    do: WorkerMaintenance.valid_page?(worker, cursor, limit)

  def valid_single_result?(worker, previous, records, cursor) do
    valid_page?(worker, cursor, 1) and advances?(previous, cursor) and
      (records == [] or match?([_record], records)) and
      Enum.all?(records, &within_page?(&1, previous, cursor))
  end

  defp advances?(previous, cursor), do: cursor == nil or previous == nil or cursor > previous

  defp within_page?(record, previous, cursor) do
    valid_record?(record) and
      within_position?(WorkerMaintenance.position(record), previous, cursor)
  end

  defp within_position?(position, previous, cursor),
    do: (previous == nil or position > previous) and (cursor == nil or position == cursor)

  # Scan the authority's complete record corpus, then select the requested
  # worker. A cursor can advance through an empty page. This also authenticates
  # rows whose SQL worker projection is missing/corrupt instead of losing them.
  def page(records, worker, cursor, limit) do
    with true <- valid_page?(worker, cursor, limit),
         true <- Enum.all?(records, &valid_record?/1) do
      selected =
        records
        |> Enum.sort_by(&WorkerMaintenance.position/1)
        |> Enum.filter(&(cursor == nil or WorkerMaintenance.position(&1) > cursor))
        |> Enum.take(limit + 1)

      examined = Enum.take(selected, limit)
      next = if length(selected) > limit, do: WorkerMaintenance.position(List.last(examined))
      {:ok, Enum.filter(examined, &(&1.worker_id == worker)), next}
    else
      _invalid -> {:error, %Error{category: :store, operation: :backend_assignments}}
    end
  end

  defp valid_record?(%Execution{} = record), do: Execution.validate(record) == :ok
  defp valid_record?(%ManagedMachine{} = record), do: ManagedMachine.validate(record) == :ok
  defp valid_record?(%Volume{} = record), do: Volume.validate(record) == :ok
  defp valid_record?(_record), do: false
end
