defmodule SmolBox.Store.SourceOwnership do
  @moduledoc """
  Host-cache preparation exclusion within one store authority.

  Adapters run `available/3` in the same transaction as machine reservation,
  while locking all of that worker's assignments. The lock is represented by
  the assigned remote machine's unfinished create intent, not an expiring lease.
  This avoids overlapping upstream downloads using the same partial file.
  Confirmed creation or explicit quiescent resolution releases it. Worker
  unavailability, observed absence, caller loss and claim expiry do not.

  All controllers and workers sharing the physical cache must use this same
  worker identity and store authority. External CLI or low-level API mutations
  cannot be coordinated by these transactions.
  """
  alias SmolBox.{Error, Source}

  def available(record, worker_id, machines) do
    if Source.remote?(record.spec.artifact) and Enum.any?(machines, &blocks?(&1, worker_id)),
      do: {:error, %Error{category: :admission_exhausted, operation: :source}},
      else: :ok
  end

  def blocks?(%{worker_id: worker_id, operation: :create, spec: spec}, worker_id),
    do: Source.remote?(spec.artifact)

  def blocks?(_record, _worker_id), do: false
end
