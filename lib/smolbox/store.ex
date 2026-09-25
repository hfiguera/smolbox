defmodule SmolBox.Store do
  @moduledoc """
  Atomic host-store boundary for managed execution and optional retained machines.

  Adapters advertising `managed_machines: 1` implement `c:machine/3` and must share
  worker leases, capacity, and assignment uniqueness across both resource kinds.
  Managed commands reference their owning machine and carry no reservation of
  their own. Their completion releases a command slot atomically, not the machine.
  Adapters advertising `extended_execution: 1` must support codec v6, terminal
  `:launched` execution evidence, atomic command-slot release after confirmed launch,
  and unknown-launch blocking. Ordinary record retention and reservations are unchanged.
  Mixed controller versions are unsupported; see the extended execution guide.

  `managed_workloads: 1` requires codec v8 and immutable startup configuration
  preserved through every machine transaction, recovery and deleted tombstone.
  No additional SQL schema is required; all readers must understand v8 first.

  `guest_files: 1` requires codec v9 and immutable path and byte-budget policy
  preserved through execution/machine transactions, recovery and tombstones.
  No SQL migration is needed; upgrade all readers before advertising support.

  `interactive_terminal: 1` additionally requires codec v7, typed terminal intent
  and exit evidence, and the same atomic managed command slot. Persist dispatch
  before opening a potentially mutating WebSocket. Unknown sessions block reuse;
  never replay input or reopen a PTY on recovery. Store no live socket or handle.

  Adapters advertising `managed_ports: 1` also atomically maintain unique
  `{worker_id, host_port}` ownership with machine assignment and reservations.
  Conflicting claims return `:port_conflict` and roll back the entire transaction.
  Retain ports until verified deletion or quiescent absence resolution; stopped,
  missing and uncertain machines keep them. Run the shared PortContract suite.
  The execution reservation rules below describe disposable work.

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

  alias SmolBox.{Error, Execution, Machine, ManagedMachine}
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

  @typedoc "Supported operations in the optional managed-machine transaction boundary."
  @type machine_operation ::
          :accept
          | :fetch
          | :list
          | :due
          | :claim
          | :claim_version
          | :write
          | :reserve
          | :request
          | :submit
          | :finish
          | :resolve

  @typedoc "The last machine ID in a scoped list page; nil starts or ends the scan."
  @type machine_list_cursor :: String.t() | nil
  @type machine_result :: {:ok, ManagedMachine.t()} | {:error, Error.t()}
  @type machine_list_result ::
          {:ok, [ManagedMachine.t()], machine_list_cursor()} | {:error, Error.t()}
  @type machine_due_result ::
          {:ok, [ManagedMachine.t()], cursor()} | {:error, Error.t()}
  @type machine_action :: :start | :stop | :delete

  @typedoc """
  Verified absence or a matching created/stopped incarnation, supplied only after
  operator quiescence. A store cannot establish quiescence from this value alone.
  """
  @type machine_resolution :: :absent | Machine.t()

  @typedoc """
  Mutable fields accepted by `:write`. Omitted fields retain their values.
  Adapters must validate the resulting record with `SmolBox.ManagedMachine`;
  these types do not authorize arbitrary lifecycle transitions. Creation evidence
  and established absence cannot be replaced. Identity, specification, assignment,
  claims, reservations and the command slot are not writable through this operation.
  """
  @type machine_changes :: [
          state:
            :accepted
            | :creating
            | :created
            | :running
            | :stopped
            | :starting
            | :stopping
            | :deleting
            | :unknown
            | :missing
            | :conflict
            | :deleted,
          operation: :create | machine_action() | nil,
          phase: :pending | :dispatching | :uncertain | nil,
          created_machine: Machine.t() | nil,
          observed_machine: Machine.t() | nil,
          next_due_at_ms: non_neg_integer(),
          last_error: Error.t() | nil,
          operation_deadline_ms: non_neg_integer() | nil,
          absence_at_ms: non_neg_integer() | nil
        ]

  @doc """
  Optional managed-machine transaction boundary.

  Advertise `managed_machines: 1` only when all operations below are implemented.
  Each operation has its own callback signature and result type. Arguments remain
  positional lists for compatibility with existing adapters. Elixir list types
  describe permitted elements, not their order or exact count; the following
  argument layouts are normative. Times are nonnegative Unix milliseconds, versions
  are positive integers, `owner` is a validated identifier and `ttl` is 1–900,000 ms.
  `key` means `t:SmolBox.ManagedMachine.key/0` except for `:finish`, which uses an
  execution key and execution guard. Guards contain owner, generation and version.

  | Operation | Ordered arguments | Success |
  |---|---|---|
  | `:accept` | `[initial_machine, max_pending]` | `{:ok, machine}` |
  | `:fetch` | `[key]` | `{:ok, machine}` |
  | `:list` | `[scope, after_id_or_nil, limit]` | `{:ok, machines, next_id_or_nil}` |
  | `:due` | `[now, after_cursor_or_nil, limit]` | `{:ok, machines, next_cursor_or_nil}` |
  | `:claim` | `[key, owner, now, ttl]` | `{:ok, machine}` |
  | `:claim_version` | `[key, expected_version, owner, now, ttl]` | `{:ok, machine}` |
  | `:write` | `[key, guard, changes, now]` | `{:ok, machine}` |
  | `:reserve` | `[key, guard, {worker_id, machine_name, capacity}, now]` | `{:ok, machine}` |
  | `:request` | `[key, action, expected_version, now]` | `{:ok, machine}` |
  | `:submit` | `[key, initial_execution, max_pending, now]` | `{:ok, execution}` |
  | `:finish` | `[execution_key, execution_guard, now]` | `{:ok, execution}` |
  | `:resolve` | `[key, guard, observation_or_absent, now]` | `{:ok, machine}` |

  All operations may return `{:error, SmolBox.Error.t()}`. An absent identity is
  `:not_found`; unavailable or corrupt storage is a store error, never absence.
  Unsupported operation names or argument layouts return `:validation`.

  ## Reading and accepting records

  `:accept` validates an initial record and atomically deduplicates by scoped
  identity and fingerprint. Matching duplicates return the existing record,
  including a deleted tombstone, even when admission is full. Different
  fingerprints return `:identity_conflict`. `max_pending` is 1–10,000 and bounds
  accepted machines for `:accept`, or accepted executions for `:submit`.

  `:fetch` includes deleted records. `:list` is scoped, sorted by ID and includes
  tombstones. `:due` scans across scopes, sorted by `{next_due_at_ms, scope, id}`,
  excluding deleted machines and machines with an active execution. Both scans
  use exclusive cursors, limits of 1–100 and return nil when no further eligible
  records remain. An empty page is `{:ok, [], nil}`, not `:not_found`.

  ## Ownership and lifecycle

  `:claim` acquires or renews the machine claim, checking the shared worker lease
  when assigned. `:claim_version` additionally checks the expected record version
  in the same transaction; mismatch returns `:stale_version` without changing it.
  `:write`, `:reserve` and `:resolve` require a valid machine guard and worker lease.
  Stale versions return `:stale_version`; invalid or expired claims return
  `:stale_claim`. Store fencing never fences requests already sent to a worker.

  `:write` applies `t:machine_changes/0`, increments the version and preserves
  immutable evidence. `:reserve` assigns an accepted machine, accounting for
  disposable and retained reservations together. Persist assignment, capacity and
  any port claims atomically; capacity exhaustion returns `:admission_exhausted`,
  assignment reuse `:identity_conflict`, and occupied ports `:port_conflict`.

  `:request` persists start/stop/delete intent against the expected version.
  Repeating the last `{action, expected_version}` returns the existing record;
  a superseded version returns `:stale_version`. Active commands or lifecycle
  work block new requests with `:admission_exhausted`. An unassigned accepted or
  conflicted machine may be deleted without a worker mutation. Assigned machines
  retain capacity and ports until verified deletion or resolved absence.

  ## Commands and recovery

  `:submit` atomically inserts an initial execution and occupies the machine's
  single command slot. It requires an idle running machine and matching scope,
  artifact and profile. Identical execution fingerprints for the same machine
  return the existing execution even when busy; other duplicates return
  `:identity_conflict`. Commands inherit assignment and creation evidence, carry
  no reservation, and share execution admission with disposable work.

  `:finish` guards the execution and updates both records atomically. Completed
  commands, confirmed background launches, and cancelled/expired commands whose
  specifications have no inputs release the command slot and mark cleanup complete.
  Other terminal or unknown outcomes retain the slot, mark machine state unknown
  and command cleanup failed. Machine capacity and ports remain reserved.

  `:resolve` handles only unknown/missing/conflicted machines after the caller
  has established operator quiescence and verified the observation. A matching
  created/stopped incarnation permits reuse; `:absent` records deletion and
  releases capacity and ports. Resolve any active terminal/unknown command in the
  same transaction, preserving its outcome while completing cleanup. Never replay
  work, delete identity history, or infer quiescence from a stopped observation.

  Every mutation must roll back machine, execution, assignment, port and capacity
  changes together on failure. `SmolBox.Store.MachineOps` and
  `SmolBox.Store.RecordOps` supply pure checks, not transactions. Run the shared
  MachineContract and PortContract suites against each adapter's actual storage.
  This contract clarification changes no callback arity, wire format or schema.
  """
  @callback machine(context(), :accept, [ManagedMachine.t() | pos_integer()]) :: machine_result()
  @callback machine(context(), :fetch, [ManagedMachine.key()]) :: machine_result()
  @callback machine(context(), :list, [String.t() | machine_list_cursor() | pos_integer()]) ::
              machine_list_result()
  @callback machine(context(), :due, [non_neg_integer() | cursor() | pos_integer()]) ::
              machine_due_result()
  @callback machine(context(), :claim, [ManagedMachine.key() | String.t() | non_neg_integer()]) ::
              machine_result()
  @callback machine(
              context(),
              :claim_version,
              [ManagedMachine.key() | String.t() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :write,
              [ManagedMachine.key() | guard() | machine_changes() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :reserve,
              [
                ManagedMachine.key()
                | guard()
                | {String.t(), String.t(), capacity()}
                | non_neg_integer()
              ]
            ) :: machine_result()
  @callback machine(
              context(),
              :request,
              [ManagedMachine.key() | machine_action() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :submit,
              [ManagedMachine.key() | Execution.t() | non_neg_integer()]
            ) :: result()
  @callback machine(context(), :finish, [Execution.key() | guard() | non_neg_integer()]) ::
              result()
  @callback machine(
              context(),
              :resolve,
              [ManagedMachine.key() | guard() | machine_resolution() | non_neg_integer()]
            ) :: machine_result()
  @optional_callbacks machine: 3

  @callback capabilities(context()) ::
              {:ok, %{schema: 1, durable: boolean(), atomic: true}} | {:error, Error.t()}
  @callback accept(context(), Execution.t(), pos_integer()) ::
              {:ok, Execution.t(), :inserted | :existing} | {:error, Error.t()}
  @callback fetch(context(), Execution.key()) :: result()
  @callback find_machine(context(), String.t(), String.t()) ::
              {:ok, Execution.t() | SmolBox.ManagedMachine.t()} | {:error, Error.t()}
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
