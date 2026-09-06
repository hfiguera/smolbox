defmodule SmolBox.Store.RecordOps do
  @moduledoc """
  Pure checks shared by store adapters. These functions provide no atomicity;
  adapters must hold the relevant record and worker transaction locks throughout.
  """

  alias SmolBox.{Error, Execution, Store, Validation}

  @spec initial(Execution.t()) :: :ok | {:error, Error.t()}
  def initial(record) do
    with :ok <- Execution.validate(record),
         {:ok, expected} <- Execution.new(record.spec, record.fingerprint, record.accepted_at_ms),
         true <- record == expected do
      :ok
    else
      _invalid -> error(:validation)
    end
  end

  @spec lease(Store.lease() | nil, String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, Store.lease()} | {:error, Error.t()}
  def lease(previous, owner, now, ttl) do
    with true <-
           Validation.identifier?(owner) and Execution.timestamp?(now) and
             Validation.integer?(ttl, 1, 900_000),
         true <- previous == nil or valid_lease?(previous) do
      lease_owner(previous, owner, now, ttl)
    else
      _invalid -> error(:validation)
    end
  end

  @spec claim(Execution.t(), Store.lease() | nil, String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, Execution.t()} | {:error, Error.t()}
  def claim(record, worker_lease, owner, now, ttl) do
    current =
      if record.claim_owner,
        do: %{
          owner: record.claim_owner,
          generation: record.generation,
          until_ms: record.claim_until_ms
        }

    with :ok <- worker_owned(record, worker_lease, owner, now),
         {:ok, claim} <- lease(current, owner, now, ttl) do
      worker_generation = if worker_lease, do: worker_lease.generation

      update(
        record,
        %{
          claim_owner: owner,
          claim_until_ms: claim.until_ms,
          generation: claim.generation,
          worker_generation: worker_generation
        },
        now
      )
    end
  end

  @spec guard(Execution.t(), Store.guard(), Store.lease() | nil, non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def guard(record, %{owner: owner, generation: generation, version: version}, worker_lease, now) do
    cond do
      not Execution.timestamp?(now) ->
        error(:validation)

      record.version != version ->
        error(:stale_version)

      {record.claim_owner, record.generation} != {owner, generation} ->
        error(:stale_claim)

      record.claim_until_ms == nil or record.claim_until_ms <= now ->
        error(:stale_claim)

      record.worker_id != nil and record.worker_generation != lease_generation(worker_lease) ->
        error(:stale_claim)

      true ->
        worker_owned(record, worker_lease, owner, now)
    end
  end

  def guard(_record, _guard, _lease, _now), do: error(:validation)

  @spec reservation(
          Execution.t(),
          String.t(),
          String.t(),
          Store.lease(),
          Store.capacity(),
          Store.resources(),
          non_neg_integer()
        ) :: {:ok, Execution.t()} | {:error, Error.t()}
  def reservation(record, worker, machine, worker_lease, capacity, used, now) do
    needed = resources(record)

    with :ok <- pending(record, now),
         true <- Validation.identifier?(worker) and SmolBox.MachineSpec.valid_name?(machine),
         :ok <- worker_owned(%{record | worker_id: worker}, worker_lease, record.claim_owner, now),
         true <- fits?(needed, used, capacity) do
      reserved = %{
        record
        | worker_id: worker,
          machine_name: machine,
          worker_generation: worker_lease.generation,
          reservation: needed
      }

      Execution.transition(reserved, [state: :preparing], now)
    else
      {:error, _error} = error -> error
      _unavailable -> error(:admission_exhausted)
    end
  end

  @spec release(Execution.t(), non_neg_integer()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def release(record, now) do
    if record.cleanup == :complete and (record.worker_id == nil or record.absence_at_ms != nil) do
      update(record, %{reservation: nil}, now)
    else
      error(:cleanup)
    end
  end

  @spec cancel(Execution.t(), non_neg_integer()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def cancel(record, now) do
    update(
      record,
      %{
        cancel_requested_at_ms: record.cancel_requested_at_ms || now,
        next_due_at_ms: min(record.next_due_at_ms, now)
      },
      now
    )
  end

  @spec resources(Execution.t()) :: Store.resources()
  def resources(record) do
    profile = record.spec.profile

    %{
      slots: 1,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb + profile.host_overhead_mb,
      disk_gb: profile.storage_gb + profile.overlay_gb
    }
  end

  @spec empty_usage() :: Store.resources()
  def empty_usage, do: %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}

  @spec due?(Execution.t(), non_neg_integer()) :: boolean()
  def due?(record, now),
    do:
      record.next_due_at_ms <= now and
        not (record.cleanup == :complete and
               (Execution.terminal?(record) or record.state == :unknown))

  @spec cursor(Execution.t()) :: Store.cursor()
  def cursor(record), do: {record.next_due_at_ms, record.scope, record.id}

  defp lease_owner(nil, owner, now, ttl),
    do: {:ok, %{owner: owner, generation: 1, until_ms: now + ttl}}

  defp lease_owner(previous, owner, now, ttl) do
    cond do
      previous.until_ms <= now ->
        {:ok, %{owner: owner, generation: previous.generation + 1, until_ms: now + ttl}}

      previous.owner == owner ->
        {:ok, %{previous | until_ms: max(previous.until_ms, now + ttl)}}

      true ->
        error(:stale_claim)
    end
  end

  defp valid_lease?(%{owner: owner, generation: generation, until_ms: until_ms}) do
    Validation.identifier?(owner) and Validation.integer?(generation, 1, 9_007_199_254_740_991) and
      Execution.timestamp?(until_ms)
  end

  defp valid_lease?(_lease), do: false
  defp lease_generation(nil), do: nil
  defp lease_generation(lease), do: lease.generation

  defp worker_owned(%{worker_id: nil}, _lease, _owner, _now), do: :ok

  defp worker_owned(_record, %{owner: owner, until_ms: until_ms}, owner, now) when until_ms > now,
    do: :ok

  defp worker_owned(_record, _lease, _owner, _now), do: error(:stale_claim)

  defp pending(record, now) do
    cond do
      record.state != :accepted or record.reservation != nil -> error(:admission_exhausted)
      Execution.expired?(record, now) -> error(:expired)
      true -> :ok
    end
  end

  defp fits?(needed, used, capacity) do
    is_map(capacity) and MapSet.new(Map.keys(capacity)) == MapSet.new(Map.keys(needed)) and
      Enum.all?(needed, fn {resource, amount} ->
        Validation.integer?(capacity[resource], 1, 1_048_576) and
          used[resource] + amount <= capacity[resource]
      end)
  end

  defp update(record, patch, now) do
    next = struct!(record, Map.merge(patch, %{version: record.version + 1, updated_at_ms: now}))

    with true <- Execution.timestamp?(now) and now >= record.updated_at_ms,
         :ok <- Execution.validate(next) do
      {:ok, next}
    else
      _invalid -> error(:validation)
    end
  end

  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
