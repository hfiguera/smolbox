defmodule SmolBox.DurableHost.Database do
  @moduledoc false
  alias Ecto.Adapters.SQL
  alias SmolBox.DurableHost.{MachineIndex, RecordCrypto}
  alias SmolBox.Error
  alias SmolBox.Store.RecordOps

  @columns "payload, fingerprint, state, version, next_due_ms, needs_work, worker_id, slots, cpus, memory_mb, disk_gb"

  def query(context, sql, params),
    do: SQL.query!(context.repo, sql, params, log: false, timeout: 5000)

  def lock(context) do
    query(
      context,
      "INSERT INTO smolbox_partitions (partition) VALUES ($1) ON CONFLICT DO NOTHING",
      [context.partition]
    )

    query(context, "SELECT partition FROM smolbox_partitions WHERE partition=$1 FOR UPDATE", [
      context.partition
    ])

    :ok
  end

  def read(context, {scope, id} = key) do
    result =
      query(
        context,
        "SELECT #{@columns} FROM smolbox_executions WHERE partition=$1 AND scope=$2 AND execution_id=$3",
        [context.partition, scope, id]
      )

    case result.rows do
      [] -> error(:not_found)
      [row] -> decode(context, key, row)
    end
  end

  def write(context, record) do
    with :ok <- MachineIndex.remember(context, record),
         {:ok, bytes} <- RecordCrypto.encrypt(record, context.key, context.partition) do
      query(
        context,
        """
        INSERT INTO smolbox_executions (partition, scope, execution_id, #{@columns})
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
        ON CONFLICT (partition,scope,execution_id) DO UPDATE SET
          payload=EXCLUDED.payload, fingerprint=EXCLUDED.fingerprint,
          state=EXCLUDED.state, version=EXCLUDED.version, next_due_ms=EXCLUDED.next_due_ms,
          needs_work=EXCLUDED.needs_work, worker_id=EXCLUDED.worker_id,
          slots=EXCLUDED.slots, cpus=EXCLUDED.cpus, memory_mb=EXCLUDED.memory_mb, disk_gb=EXCLUDED.disk_gb
        """,
        [context.partition, record.scope, record.id, bytes | projection(record)]
      )

      {:ok, record}
    end
  end

  def pending_count(context) do
    %{rows: [[count]]} =
      query(
        context,
        "SELECT count(*) FROM smolbox_executions WHERE partition=$1 AND state='accepted'",
        [context.partition]
      )

    count
  end

  def worker_lease(_context, nil), do: nil

  def worker_lease(context, worker) do
    case query(
           context,
           "SELECT owner,generation,until_ms FROM smolbox_worker_leases WHERE partition=$1 AND worker_id=$2",
           [context.partition, worker]
         ).rows do
      [] ->
        nil

      [[owner, generation, until_ms]] ->
        %{owner: owner, generation: generation, until_ms: until_ms}
    end
  end

  def put_lease(context, worker, lease) do
    query(
      context,
      """
      INSERT INTO smolbox_worker_leases (partition,worker_id,owner,generation,until_ms)
      VALUES ($1,$2,$3,$4,$5) ON CONFLICT (partition,worker_id) DO UPDATE SET
        owner=EXCLUDED.owner, generation=EXCLUDED.generation, until_ms=EXCLUDED.until_ms
      """,
      [context.partition, worker, lease.owner, lease.generation, lease.until_ms]
    )

    {:ok, lease}
  end

  def usage(context, worker) do
    %{rows: [[slots, cpus, memory, disk]]} =
      query(
        context,
        """
        SELECT COALESCE(sum(slots),0), COALESCE(sum(cpus),0), COALESCE(sum(memory_mb),0), COALESCE(sum(disk_gb),0)
        FROM smolbox_executions WHERE partition=$1 AND worker_id=$2
        """,
        [context.partition, worker]
      )

    {:ok, %{slots: slots, cpus: cpus, memory_mb: memory, disk_gb: disk}}
  end

  def due(context, now, cursor, limit) do
    {tail, params} =
      case cursor do
        nil ->
          {"ORDER BY next_due_ms,scope,execution_id LIMIT $3",
           [context.partition, now, limit + 1]}

        {time, scope, id} ->
          {"AND (next_due_ms,scope,execution_id)>($3,$4,$5) ORDER BY next_due_ms,scope,execution_id LIMIT $6",
           [context.partition, now, time, scope, id, limit + 1]}
      end

    rows =
      query(
        context,
        "SELECT scope,execution_id,#{@columns} FROM smolbox_executions WHERE partition=$1 AND needs_work AND next_due_ms<=$2 " <>
          tail,
        params
      ).rows

    with {:ok, records} <- decode_rows(context, rows) do
      page = Enum.take(records, limit)
      next = if length(records) > limit, do: RecordOps.cursor(List.last(page))
      {:ok, page, next}
    end
  end

  defp decode_rows(context, rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn [scope, id | row], {:ok, records} ->
      case decode(context, {scope, id}, row) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp decode(context, key, [bytes | projected]) do
    with {:ok, record} <- RecordCrypto.decrypt(bytes, context.key, context.partition, key),
         true <- projected == projection(record) do
      {:ok, record}
    else
      _invalid -> error(:store)
    end
  end

  defp projection(record) do
    resources = record.reservation || RecordOps.empty_usage()

    [
      record.fingerprint,
      Atom.to_string(record.state),
      record.version,
      record.next_due_at_ms,
      RecordOps.needs_work?(record),
      record.worker_id,
      resources.slots,
      resources.cpus,
      resources.memory_mb,
      resources.disk_gb
    ]
  end

  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
