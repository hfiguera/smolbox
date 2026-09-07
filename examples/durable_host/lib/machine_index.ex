defmodule SmolBox.DurableHost.MachineIndex do
  @moduledoc false
  alias SmolBox.DurableHost.Database
  alias SmolBox.Error

  @unindexed """
  FROM smolbox_executions e
  LEFT JOIN smolbox_machine_identities i USING(partition, scope, execution_id)
  WHERE e.partition=$1 AND e.worker_id IS NOT NULL AND i.scope IS NULL
  """

  def ready(context) do
    case Database.query(context, "SELECT 1 " <> @unindexed <> " LIMIT 1", [context.partition]).rows do
      [] -> :ok
      _incomplete -> error(:store)
    end
  end

  def remember(_context, %{worker_id: nil}), do: :ok

  def remember(context, record) do
    %{rows: [[scope, id]]} =
      Database.query(
        context,
        """
        INSERT INTO smolbox_machine_identities (partition,worker_id,machine_name,scope,execution_id)
        VALUES ($1,$2,$3,$4,$5)
        ON CONFLICT (partition,worker_id,machine_name) DO UPDATE SET
          execution_id=smolbox_machine_identities.execution_id
        RETURNING scope,execution_id
        """,
        [context.partition, record.worker_id, record.machine_name, record.scope, record.id]
      )

    if {scope, id} == {record.scope, record.id}, do: :ok, else: error(:identity_conflict)
  end

  def find(context, worker, name) do
    with :ok <- ready(context) do
      result =
        Database.query(
          context,
          "SELECT scope,execution_id FROM smolbox_machine_identities WHERE partition=$1 AND worker_id=$2 AND machine_name=$3",
          [context.partition, worker, name]
        )

      resolve(context, result.rows, worker, name)
    end
  end

  def backfill_one(context) do
    rows =
      Database.query(
        context,
        "SELECT e.scope,e.execution_id " <>
          @unindexed <> " ORDER BY e.scope,e.execution_id LIMIT 1",
        [context.partition]
      ).rows

    case rows do
      [] -> {:ok, :done}
      [[scope, id]] -> backfill_record(context, {scope, id})
    end
  end

  defp backfill_record(context, key) do
    with {:ok, record} <- Database.read(context, key),
         :ok <- remember(context, record),
         do: {:ok, :more}
  end

  defp resolve(_context, [], _worker, _name), do: error(:not_found)

  defp resolve(context, [[scope, id]], worker, name) do
    with {:ok, record} <- Database.read(context, {scope, id}) do
      if record.worker_id == worker and record.machine_name == name,
        do: {:ok, record},
        else: error(:store)
    end
  end

  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
