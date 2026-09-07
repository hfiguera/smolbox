defmodule SmolBox.Store do
  @moduledoc """
  Atomic host-store boundary for managed execution.

  Every mutation is one transaction. Failures must roll back record and worker
  changes together. Reads are authoritative and must never translate unavailable,
  corrupt, or unknown-schema storage into `not_found`. There is no fallback store.

  `accept` inserts only an initial validated record. An identical scoped fingerprint
  returns the existing record even when the pending queue is full; conflicting
  fingerprints fail. Queue limits count accepted work across this store namespace.

  Worker leases enforce one active owner within a shared store. Claims and record
  versions fence subsequent writes, not already-sent HTTP. A new claim generation
  cannot authorize replay of dispatching/running/unknown work. Operators must map
  each physical worker to one stable ID and one shared store authority.

  Reservation atomically checks the worker lease, execution claim, record version,
  queue deadline, and CPU/memory/disk/slot totals. It persists worker and opaque
  machine identity before creating a VM. Release requires completed cleanup and
  confirmed absence once a worker has been assigned. Unknown or failed-cleanup
  records retain reservations until this condition is met.

  Due queries are bounded keyset scans ordered by `{next_due_at_ms, scope, id}`.
  A fresh process can restart at a nil cursor; notifications and PIDs are not state.
  Completed clean records are retained for identity lookup, not silently removed.
  Adapters must document retention and database/storage limits independently.

  `find_machine` resolves a worker/name assignment through durable evidence. Its
  index is updated atomically with reservation and retained after cleanup. Names
  cannot be assigned to another execution on that worker. Missing, unavailable,
  corrupt, or incompletely migrated indexes must not be conflated. This lookup
  proves an assignment, not the current machine's incarnation or ownership.

  Implementations may share the pure record operations, but must independently
  pass the adapter conformance suite and demonstrate their transaction semantics.
  """

  alias SmolBox.{Error, Execution}
  @type context :: term()
  @type guard :: %{owner: String.t(), generation: pos_integer(), version: pos_integer()}
  @type lease :: %{owner: String.t(), generation: pos_integer(), until_ms: non_neg_integer()}
  @type capacity :: %{
          slots: pos_integer(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          disk_gb: pos_integer()
        }
  @type cursor :: {non_neg_integer(), String.t(), String.t()} | nil
  @type result :: {:ok, Execution.t()} | {:error, Error.t()}
  @type resources :: %{
          slots: non_neg_integer(),
          cpus: non_neg_integer(),
          memory_mb: non_neg_integer(),
          disk_gb: non_neg_integer()
        }

  @callback capabilities(context()) ::
              {:ok, %{schema: 1, durable: boolean(), atomic: true}} | {:error, Error.t()}
  @callback accept(context(), Execution.t(), pos_integer()) ::
              {:ok, Execution.t(), :inserted | :existing} | {:error, Error.t()}
  @callback fetch(context(), Execution.key()) :: result()
  @callback find_machine(context(), String.t(), String.t()) :: result()
  @callback claim_worker(context(), String.t(), String.t(), non_neg_integer(), pos_integer()) ::
              {:ok, lease()} | {:error, Error.t()}
  @callback claim(context(), Execution.key(), String.t(), non_neg_integer(), pos_integer()) ::
              result()
  @callback write(context(), Execution.key(), guard(), keyword(), non_neg_integer()) :: result()
  @callback reserve(
              context(),
              Execution.key(),
              guard(),
              {String.t(), String.t(), capacity()},
              non_neg_integer()
            ) :: result()
  @callback release(context(), Execution.key(), guard(), non_neg_integer()) :: result()
  @callback cancel(context(), Execution.key(), non_neg_integer()) :: result()
  @callback due(context(), non_neg_integer(), cursor(), pos_integer()) ::
              {:ok, [Execution.t()], cursor()} | {:error, Error.t()}
  @callback usage(context(), String.t()) :: {:ok, resources()} | {:error, Error.t()}
end
