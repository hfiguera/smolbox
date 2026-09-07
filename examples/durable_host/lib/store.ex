defmodule SmolBox.DurableHost.Store do
  @moduledoc """
  Host-owned Ecto/Postgres store example with encrypted execution payloads.

  Mutations serialize on a partition row, while indexed record reads and due scans
  use ordinary committed reads. Each physical worker must belong to one stable
  partition/store authority. This intentionally prioritizes simple transaction
  semantics for a small pool; it is not an unlimited-throughput production adapter.
  """
  @behaviour SmolBox.Store

  alias SmolBox.DurableHost.{Database, MachineIndex}
  alias SmolBox.{Error, Execution, MachineSpec, Validation}
  alias SmolBox.Store.RecordOps

  @enforce_keys [:repo, :partition, :key]
  @derive {Inspect, only: [:partition]}
  defstruct [:repo, :partition, :key]

  def new(repo, partition, key) do
    if is_atom(repo) and Validation.identifier?(partition) and is_binary(key) and
         byte_size(key) == 32 do
      {:ok, %__MODULE__{repo: repo, partition: partition, key: key}}
    else
      error(:validation)
    end
  end

  @impl SmolBox.Store
  def capabilities(context) do
    safe(fn ->
      Database.query(
        context,
        "SELECT e.payload,w.owner,p.partition FROM smolbox_partitions p LEFT JOIN smolbox_executions e USING(partition) LEFT JOIN smolbox_worker_leases w USING(partition) LIMIT 0",
        []
      )

      with :ok <- MachineIndex.ready(context),
           do: {:ok, %{schema: 1, durable: true, atomic: true}}
    end)
  end

  @impl SmolBox.Store
  def accept(context, record, max_pending) do
    with :ok <- RecordOps.initial(record), true <- Validation.integer?(max_pending, 1, 10_000) do
      transaction(context, fn -> accept_record(context, record, max_pending) end)
    else
      _invalid -> error(:validation)
    end
  end

  @impl SmolBox.Store
  def fetch(context, key), do: safe(fn -> Database.read(context, key) end)

  @impl SmolBox.Store
  def find_machine(context, worker, name) do
    if Validation.identifier?(worker) and MachineSpec.valid_name?(name),
      do: safe(fn -> MachineIndex.find(context, worker, name) end),
      else: error(:validation)
  end

  @doc "Backfill one authenticated assignment in this partition under a transaction; run before runtime startup."
  def backfill_machine_index(context),
    do: transaction(context, fn -> MachineIndex.backfill_one(context) end)

  @impl SmolBox.Store
  def claim_worker(context, worker, owner, now, ttl) do
    if Validation.identifier?(worker) do
      transaction(context, fn -> renew_worker(context, worker, owner, now, ttl) end)
    else
      error(:validation)
    end
  end

  defp renew_worker(context, worker, owner, now, ttl) do
    with {:ok, lease} <- RecordOps.lease(Database.worker_lease(context, worker), owner, now, ttl) do
      Database.put_lease(context, worker, lease)
    end
  end

  @impl SmolBox.Store
  def claim(context, key, owner, now, ttl) do
    mutate(context, key, fn record ->
      RecordOps.claim(record, Database.worker_lease(context, record.worker_id), owner, now, ttl)
    end)
  end

  @impl SmolBox.Store
  def write(context, key, guard, changes, now) do
    guarded(context, key, guard, now, &Execution.transition(&1, changes, now))
  end

  @impl SmolBox.Store
  def reserve(context, key, guard, {worker, machine, capacity}, now) do
    guarded(context, key, guard, now, fn record ->
      {:ok, used} = Database.usage(context, worker)

      RecordOps.reservation(
        record,
        worker,
        machine,
        Database.worker_lease(context, worker),
        capacity,
        used,
        now
      )
    end)
  end

  @impl SmolBox.Store
  def release(context, key, guard, now),
    do: guarded(context, key, guard, now, &RecordOps.release(&1, now))

  @impl SmolBox.Store
  def cancel(context, key, now), do: mutate(context, key, &RecordOps.cancel(&1, now))
  @impl SmolBox.Store
  def usage(context, worker), do: safe(fn -> Database.usage(context, worker) end)
  @impl SmolBox.Store
  def due(context, now, cursor, limit) do
    if Execution.timestamp?(now) and valid_cursor?(cursor) and Validation.integer?(limit, 1, 100) do
      safe(fn -> Database.due(context, now, cursor, limit) end)
    else
      error(:validation)
    end
  end

  defp accept_record(context, record, max_pending) do
    case Database.read(context, Execution.key(record)) do
      {:ok, %{fingerprint: fingerprint} = existing} when fingerprint == record.fingerprint ->
        {:ok, existing, :existing}

      {:ok, _conflict} ->
        error(:identity_conflict)

      {:error, %Error{category: :not_found}} ->
        insert_record(context, record, max_pending)

      error ->
        error
    end
  end

  defp insert_record(context, record, max_pending) do
    if Database.pending_count(context) < max_pending do
      with {:ok, record} <- persist(context, record), do: {:ok, record, :inserted}
    else
      error(:admission_exhausted)
    end
  end

  defp guarded(context, key, guard, now, function) do
    mutate(context, key, fn record ->
      with :ok <-
             RecordOps.guard(record, guard, Database.worker_lease(context, record.worker_id), now),
           do: function.(record)
    end)
  end

  defp mutate(context, key, function) do
    transaction(context, fn ->
      with {:ok, record} <- Database.read(context, key),
           {:ok, next} <- function.(record) do
        persist(context, next)
      end
    end)
  end

  # Both writes belong to the caller's partition transaction. A record write
  # failure must roll back the identity assignment as well.
  defp persist(context, record) do
    with :ok <- MachineIndex.remember(context, record), do: Database.write(context, record)
  end

  defp transaction(context, function) do
    safe(fn ->
      context.repo.transact(
        fn ->
          :ok = Database.lock(context)

          transaction_result(function.())
        end,
        timeout: 5000,
        log: false
      )
      |> unwrap()
    end)
  end

  defp transaction_result({:error, error}), do: {:error, error}
  defp transaction_result(result), do: {:ok, result}

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, error}), do: {:error, error}
  defp valid_cursor?(nil), do: true

  defp valid_cursor?({now, scope, id}),
    do: Execution.timestamp?(now) and Validation.identifier?(scope) and Validation.identifier?(id)

  defp valid_cursor?(_cursor), do: false

  defp safe(function) do
    function.()
  rescue
    _redacted -> error(:store, :dispatch_uncertain)
  catch
    :exit, _redacted -> error(:store, :dispatch_uncertain)
  end

  defp error(category, evidence \\ :not_dispatched),
    do: {:error, %Error{category: category, operation: :store, evidence: evidence}}
end
