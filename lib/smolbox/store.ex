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

  `registry_sources: 1` requires codec v10, immutable remote source identity and
  preparation evidence, and atomic host-cache exclusion during remote creation.
  In the reservation transaction, exclude another assigned remote machine whose
  create intent remains unfinished on that worker. Lease expiry, missing worker
  machines and preparation timeout do not release this exclusion. Confirmed
  creation or explicit operator-quiescent resolution does. See
  `SmolBox.Store.SourceOwnership`. Controllers sharing a physical worker cache
  must share one worker identity and store authority. The PostgreSQL example
  uses its existing partition transaction and indexed worker assignment scan;
  no additional SQL migration is required, but every adapter must implement
  the new transaction behavior before advertising the capability.

  `interactive_terminal: 1` additionally requires codec v7, typed terminal intent
  and exit evidence, and the same atomic managed command slot. Persist dispatch
  before opening a potentially mutating WebSocket. Unknown sessions block reuse;
  never replay input or reopen a PTY on recovery. Store no live socket or handle.

  `managed_images: 1` requires codec v10, `SmolBox.ImagePull` intent and
  `SmolBox.Image` results, `:image_pulled` evidence in completed executions, and
  the same atomic managed-operation slot. Image pulls never reserve or release
  machine capacity themselves. Unknown pulls block reuse like unknown commands.
  Run the shared ImageContract; no additional SQL table is needed.

  Adapters advertising `managed_ports: 1` also atomically maintain unique
  `{worker_id, host_port}` ownership with machine assignment and reservations.
  Conflicting claims return `:port_conflict` and roll back the entire transaction.
  Retain ports until verified deletion or quiescent absence resolution; stopped,
  missing and uncertain machines keep them. Run the shared PortContract suite.
  The execution reservation rules below describe disposable work.

  `managed_exports: 1` requires codec v11, atomic export history and resource
  accounting. Each `SmolBox.Export` is a distinct record retained inside its
  machine, including tombstones. Run `ExportContract`. The store must reserve
  publication tag identities across all retained histories and keep the active
  export's additional resources in worker usage until terminal resolution. No
  SQL migration is needed in the example; upgrade every reader and projection
  implementation before enabling this capability. Ordinary records keep their
  previous codec and resource projection. History admits at most 256 exports per
  machine; it never expires or evicts an identity to make room.

  `local_volumes: 1` requires codec v15 and the optional volume callbacks below.
  Atomically attach all scoped volume references with managed-machine acceptance,
  pin the worker and resolved mounts, and retain exclusive attachment until verified
  deletion. Volume disk allowance participates in every admission and drain gate;
  stopping/deleting machines does not release that allowance. Keep tombstones for
  deduplication. Never replay pending volume operations. Run `VolumeContract` and
  coordinate all readers/projection writers plus the example volume migration.

  `native_volumes: 1` additionally requires native volume proof/history readers
  (v20) and mounted machine/command readers (v21), exact backend binding on
  acceptance, atomic proof-bound attachment/release and independent accounting.
  Native recovery pages include volume tombstones and pending intents without
  importing proofs or replaying mutations. Run `NativeVolumeContract` against
  every adapter before advertising this marker. Reader support does not enable
  a helper's volume descriptor or approve a native package.

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
          | :branch_delete_action_accept
          | :branch_delete_action_complete
          | :branch_delete_accept
          | :export_accept
          | :export_advance
          | :export_cancel
          | :export_resolve
          | :expansion_accept
          | :expansion_advance

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
  @type machine_resolution ::
          :absent | Machine.t() | SmolBox.Embedded.BranchDeletionResolution.t()

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
          phase: :pending | :preparing | :prepared | :dispatching | :uncertain | nil,
          preparation: SmolBox.ArtifactPreparation.t() | nil,
          created_machine: Machine.t() | nil,
          observed_machine: Machine.t() | nil,
          next_due_at_ms: non_neg_integer(),
          last_error: Error.t() | nil,
          operation_deadline_ms: non_neg_integer() | nil,
          absence_at_ms: non_neg_integer() | nil
        ]

  @doc """
  Optional managed-machine transaction boundary.

  Advertise `managed_machines: 1` only when all core operations below are implemented.
  Capture, export and branch operations additionally require their feature capabilities.
  Each operation has its own callback signature and result type. Arguments remain
  positional lists for compatibility with existing adapters. Elixir list types
  describe permitted elements, not their order or exact count; the following
  argument layouts are normative. Times are nonnegative Unix milliseconds, versions
  are positive integers, `owner` is a validated identifier and `ttl` is 1–900,000 ms.
  `key` means `t:SmolBox.ManagedMachine.key/0` except for `:finish`, which uses an
  execution key and execution guard. Guards contain owner, generation and version.

  | Operation | Ordered arguments | Success |
  |---|---|---|
  | `:expansion_accept` | `[key, id, version, targets, capacity, now]` | `{:ok, machine}` |
  | `:expansion_advance` | `[key, guard, id, expected_state, outcome, now]` | `{:ok, machine}` |
  | `:accept` | `[initial_machine, max_pending]` | `{:ok, machine}` |
  | `:fetch` | `[key]` | `{:ok, machine}` |
  | `:list` | `[scope, after_id_or_nil, limit]` | `{:ok, machines, next_id_or_nil}` |
  | `:due` | `[now, after_cursor_or_nil, limit]` | `{:ok, machines, next_cursor_or_nil}` |
  | `:claim` | `[key, owner, now, ttl]` | `{:ok, machine}` |
  | `:claim_version` | `[key, expected_version, owner, now, ttl]` | `{:ok, machine}` |
  | `:write` | `[key, guard, changes, now]` | `{:ok, machine}` |
  | `:reserve` | `[key, guard, allocation, now]` (`t:allocation/0`) | `{:ok, machine}` |
  | `:request` | `[key, action, expected_version, now]` | `{:ok, machine}` |
  | `:submit` | `[key, initial_execution, max_pending, now]` | `{:ok, execution}` |
  | `:finish` | `[execution_key, execution_guard, now]` | `{:ok, execution}` |
  | `:resolve` | `[key, guard, observation_or_absent, now]` | `{:ok, machine}` |
  | `:branch_delete_accept` (native) | `[key, guard, now]` | `{:ok, machine}` |
  | `:branch_delete_action_accept` (native) | `[key, guard, action, now]` | `{:ok, machine}` |
  | `:branch_delete_action_complete` (native) | `[key, guard, action, proof, now]` | `{:ok, machine}` |
  | `:resolve` (native held delete) | `[key, guard, deletion_resolution_proof, now]` | `{:ok, machine}` |
  | `:capture_accept` | `[key, spec, fingerprint, capacity, now]` | `{:ok, machine}` |
  | `:capture_advance` | `[key, guard, capture_id, expected_state, changes, now]` | `{:ok, machine}` |
  | `:capture_cancel` | `[key, capture_id, now]` | `{:ok, machine}` |
  | `:capture_resolve` | `[key, guard, capture_id, running_or_stopped_observation_or_absent, now]` | `{:ok, machine}` |
  | `:capture_release` | `[key, guard, capture_id, now]` | `{:ok, machine}` |
  | `:capture_release` | `[key, guard, capture_id, native_cleanup, now]` (native captures) | `{:ok, machine}` |
  | `:export_accept` | `[key, spec, fingerprint, capacity, now]` | `{:ok, machine}` |
  | `:export_advance` | `[key, guard, export_id, expected_state, changes, now]` | `{:ok, machine}` |
  | `:export_cancel` | `[key, export_id, now]` | `{:ok, machine}` |
  | `:export_resolve` | `[key, guard, export_id, stopped_observation_or_absent, now]` | `{:ok, machine}` |
  | `:branch_accept` | `[source_key, spec, fingerprint, child_name, capacity, now]` | `{:ok, child}` |
  | `:branch_advance` | `[source_key, source_guard, child_id, expected_state, change, now]` | `{:ok, child}` |
  | `:branch_resolve` | `[source_key, source_guard, child_id, source_or_absent, child_or_absent, now]` | `{:ok, child}` |
  | `:branch_retire` | `[source_key, source_guard, child_id, now]` | `{:ok, child}` |
  | `:branch_retire` (native) | `[source_key, source_guard, child_id, child_absence_proof, now]` | `{:ok, child}` |
  | `:branch_backing_accept` (native) | `[source_key, source_guard, child_id, child_version, backing_removed, now]` | `{:ok, child}` |
  | `:branch_release_storage` (native) | `[source_key, source_guard, child_id, backing_release_proof, now]` | `{:ok, child}` |
  | `:branch_release_storage` | `[source_key, source_guard, child_id, now]` | `{:ok, child}` |
  | `:branch_release` | `[child_key, expected_version, now]` | `{:ok, child}` |
  | `:branch_release_advance` | `[child_key, child_guard, expected_state, change, now]` | `{:ok, child}` |

  Native backing release first uses `:branch_backing_accept` to save the exact
  request under the source guard and child version. Both records must be deleted,
  every source dependency retired, and the child's original completion and typed
  retirement retained. Acceptance preserves all backing capacity. Claim/version
  changes retain the accepted request. A typed matching acknowledgement is then
  required by the native `:branch_release_storage` variant to close the branch and
  release only its extra backing reservation. Both operations must lock and
  persist source, child and resource projections atomically. Missing replies keep
  the public charge; adapters must never reconstruct a request after dispatch.

  Native branch advancement accepts `{:native_complete, NativeBranchResult}` only
  after dispatch. The result combines the original typed completion with two
  positive current observations, including the original source PID/birth. Commit
  the source publication/history and immutable child root/current material in the
  same transaction; retain the child and extra backing reservations. Explicit
  resolution of an unknown native branch uses that same result in the child
  observation position and its exact source observation in the source position.
  A historical completion alone, missing lookup, bare Machine or absence atom
  cannot establish native completion or release capacity. Native branch admission
  remains disabled until the complete native lifecycle/store contract is enabled.

  Native held release also locks source and child atomically. Acceptance freezes
  the public release version, a new request/deadline, the current source head and
  both original process identities. Advance is fenced by the child guard and
  preserves the source lock on uncertainty. `{:native_complete,
  NativeBranchReleaseResult}` requires explicit release proof and current source/
  child observations; explicit kept resolution uses the same source/result pair.
  Neither success nor resolution frees backing. Bare Machine acknowledgments
  cannot complete native release. Readers/writers of selective v31 must upgrade
  together before native held release can be enabled.

  Native dependency retirement additionally requires a typed
  `SmolBox.Embedded.BranchChildAbsence` from the fenced backend. Bind the proof to
  the child's exact saved completion/head, fingerprint and observed version;
  reject stale responses even if the source guard remains current. The child
  must already be durably deleted. Atomically retain immutable retirement proof
  and original child version while marking only that source dependency retired.
  Preserve source material/history, child creation/current material and all extra
  backing charges. Bare absence, a deleted state or host assertion cannot replace
  this proof. Selective v32 readers and all paired writers must upgrade together;
  current stores still do not advertise the complete `native_branches: 1` marker.

  Expansion acceptance atomically deduplicates operation identity, validates the
  machine version and exclusion, reserves disk growth, and enforces durable drain.
  Advance requires the existing machine guard. Unknown outcomes retain requested
  disk sizes; no replay or release based on stale observations is permitted.
  Advertise `managed_disk_expansion: 1` only with codec v14 and all resource
  projection writers upgraded. Run ExpansionContract against the real adapter.

  `managed_branches: 1` additionally requires all branch operations. Admission
  atomically locks both scoped identities, the source operation slot, worker name
  ownership and combined worker capacity. Matching child fingerprint plus source
  identity deduplicates even after deletion; any other occupied child ID conflicts.
  Persist both records and resource projections in one transaction, rolling back
  the source if child persistence fails. Guarded pair operations validate the
  source guard, recorded relationship and expected child state, never trusting a
  name alone. Release advances use the child's guard and expected branch state.
  A repeated release with its original submitted version returns stored evidence.
  These transactions must serialize with commands, files, PTYs, capture, export
  and lifecycle admission across controllers sharing the store.

  `BranchOps` defines branch transitions. Cancellation before dispatch unlocks the
  source and releases extra capacity. After dispatch, uncertainty retains the lock
  and resources. Resolve requires caller-confirmed quiescence plus verified
  ownership or absence; it never manufactures a creation receipt or replays work.
  Retirement requires child deletion and quiescence; it releases only the source
  dependency. Storage release additionally requires source deletion and host
  confirmation of backing cleanup. Both source and child absence are verified by
  the caller. Project `RecordOps.accounted_resources/1` even for deleted children:
  the full backing allowance remains until branch state `:closed`. Never garbage
  collect tombstones or branch history. Run the shared `BranchContract` scenarios
  against each adapter, including concurrent admission and transactional rollback.

  `managed_checkpoints: 1` additionally requires every capture operation and
  resource projection from `RecordOps.accounted_resources/1`, including
  deleted machines with retained capture disks. Admission checks combined capacity;
  advance compares the expected capture state as well as the machine guard.
  Cancellation after dispatch retains uncertainty. Resolve requires caller-supplied
  request/staging quiescence evidence and source ownership or verified absence.
  Release requires host confirmation that retained copies were removed. Adapters
  must persist history and the resource projection atomically; run CaptureContract.

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

  Original native held-delete uncertainty requires `:branch_delete_accept` before
  helper IO. It freezes the claimed version, original delete request version and
  exact completion/root-bound request; later claims retain it unchanged. Native
  `:resolve` requires its typed matching deletion-resolution proof and atomically
  retains that proof while releasing only the child's ordinary reservation.
  Source dependencies and extra backing remain charged for their separate paired
  retirement/release transactions. Bare absence or a generic uncertain-to-deleted
  write cannot substitute. Pending/complete authority uses selective codec v34;
  upgrade every reader and resource projection writer before native activation.

  Explicit held-delete continuation and residual cleanup use separate
  `:branch_delete_action_accept` / `:branch_delete_action_complete` commands with
  action `:continue` or `:cleanup`. Accept freezes the current claimed management
  version, original delete version and exact action request before IO. Claims and
  retries preserve it. Complete requires the matching typed continuation or
  cleanup acknowledgement and atomically releases only the ordinary child slot.
  Distinct pending action and observational requests remain as immutable history
  when another acknowledgement finishes deletion; they cannot authorize new IO
  after deletion. Source dependency and persistent backing remain separate.
  Pending/completed action slots use selective codec v35. Every reader and resource
  projection writer must upgrade before native activation; no capability marker
  is introduced here. Generic resolve does not consume action acknowledgements.

  Original released-child observation, SDK continuation and residual cleanup use
  distinct saved grants in the same slots, selectively encoded as v40, v41 and
  v42 respectively. They bind the full original completion, release and current
  head as well as claimed management/delete versions. Cleanup consumes its exact
  typed positive-absence proof; it cannot substitute for an independently accepted
  observation or SDK-success proof. Completing any route preserves other pending
  grants as immutable history and retires only the ordinary child reservation.
  Every shared reader/projector must upgrade before native activation.

  Original deletion collection uses these same commands with action `:collect`,
  a separate `delete_collection` history and selective codec v43. Acceptance freezes
  the exact original completion/release/child and management/delete versions before
  IO. Completion consumes only its matching typed historical collection proof,
  changing no delete state, operation phase, ordinary child reservation, source
  dependency or backing charge. It gives no readiness/deletion/absence authority
  and cannot satisfy another accepted action. Source and other accepted histories
  remain unchanged. Existing final deletion routes preserve this history.
  Earlier envelopes omit the new nil default exactly and restore it on read;
  older tags cannot carry collection state. Upgrade every reader/projector first.

  Pre-handoff child collection uses `:branch_advance` with
  `{:accept_partial_collection, child_version, platform}` followed by
  `{:complete_partial_collection, typed_result}`. Both records must retain the
  original source head, active dependency and unknown creation. Acceptance freezes
  the full creation, management version, explicit quiescence and pinned platform
  before helper IO. Completion requires its exact typed proof and current child
  version. It records historical original-child collection only: creation stays
  unknown and no slot, port, disk, source dependency or backing is released.
  Exact saved acknowledgement reads are idempotent. Generic readiness, absence,
  disposal and prepared-only retirement cannot consume this grant. The selective
  v44 envelope and `native_partial_branch_collections: 1` marker require all
  readers/projectors to upgrade; this marker does not enable native branches.
  Run NativePartialBranchCollectionContract against each real adapter.

  Original collected pre-handoff disposal freezes a separate action with
  `{:accept_partial_disposal, child_version, platform}` in `:branch_advance`.
  A completed original collection must already exist. Acceptance preserves that
  history and every reservation, changing only the distinct disposal-pending
  phase. `:branch_resolve` consumes `NativePartialBranchDisposalResult` beside
  its exact fresh source observation. Require matching full prior collection,
  publication, optional release, platform, immutable action and current child
  version. Commit the disposed tombstone and actual source publication together;
  release only ordinary child capacity. Keep source dependency and extra backing
  charged until their explicit cleanup protocols complete. Selective v45 and
  `native_partial_branch_disposals: 1` require reader-first upgrades. They enable
  no public native branches. Run NativePartialBranchDisposalContract against
  each real adapter. `Branches.dispose_partial/4` and deleted branch resolution
  now fence acceptance, native proof plus fresh source observation, and paired
  completion through the same controller/helper owner. Backend/Runtime dispatch
  preserves exact saved acknowledgement lookup and conservative retry semantics;
  ordinary current-package qualification and public branch activation remain separate.

  Original partial-disposal residual cleanup freezes a nested immutable action
  with `{:accept_partial_disposal_cleanup, child_version, platform}` after original
  collection and disposal acceptance. Its distinct `:disposal_cleanup_pending`
  phase preserves every reservation, source dependency and backing allowance.
  `:branch_resolve` consumes `NativePartialBranchCleanupResult` paired with its
  exact fresh source observation. The typed acknowledgement must bind the saved
  cleanup request and original resolved-absent disposal. Commit both records and
  both acknowledgement histories together; release only ordinary child capacity.
  Ordinary disposal cannot bypass an accepted cleanup. Selective v48 and
  `native_partial_branch_cleanups: 1` require reader-first upgrades, and enable no
  native branch feature. Run NativePartialBranchCleanupContract against each real
  adapter. `Branches.cleanup_partial/4` now fences acceptance, native cleanup plus
  source observation and paired commit. Accepted retries preserve the exact
  request; already accepted cleanup is also resumed by deleted resolution. Native
  eligibility/remaining partial-state recovery and ordinary package qualification
  remain required before public activation.

  An accepted cleanup made unnecessary by original terminal disposal instead
  consumes `NativePartialBranchCleanupResolutionResult` in `:branch_resolve`,
  paired with its exact fresh source observation. Its distinct typed proof binds
  the same saved action and preserves Deleted/ResolvedAbsent provenance. Atomic
  completion records cleanup.unneeded while cleanup.proof remains nil; it never
  claims residual removal or releases dependencies/backing. Selective v49 and
  `native_partial_branch_cleanup_resolutions: 1` require reader-first upgrades.
  Old pending/removal records keep v48 with the new nil default omitted exactly.
  Both Memory and PostgreSQL use these paired guards. The public coordinator now
  consumes the distinct result under its original controller/helper fence after
  bounded optional history lookup and fresh source observation. Missing history
  cannot authorize removal. Ordinary package qualification and other partial
  states remain required; this store marker enables no native branch capability.

  Prepared-only creation resolution uses the distinct
  `SmolBox.Embedded.NativePreparedBranchRetirementResult` in the child observation
  position, paired with its exact fresh source observation. Bind the typed proof
  to the immutable full creation request, original source PID, resource plan and
  current child version. The source's current material head must remain the
  original request head. In one transaction, retain the same immutable retirement
  entry on both records, close the never-created child, retire its dependency and
  release its ordinary plus pre-entry reservations. Neither created_machine nor
  observed_machine is manufactured for that child. The tagged source history entry
  is excluded from material transitions and permanently reserves its operation ID.
  Entered work, missing proof, generic absence and stale versions retain all
  reservations. Selective v36 requires reader/resource-writer upgrades; public
  native admission remains disabled pending its separate gates. Public resolution
  retains the original helper/controller fence through the final pair transaction.
  Run NativePreparedBranchRetirementContract against each real adapter.

  Entered, published never-booted disposal first saves
  `{:accept_unbooted_disposal, child_version}` through `:branch_advance` while the
  source and child are locked. Preserve its exact creation-bound request across
  claims and uncertainty, with every reservation still charged. Completion uses
  `SmolBox.Embedded.NativeUnbootedBranchDisposalResult` in the `:branch_resolve`
  child observation position, paired with its fresh source observation. Require
  the current child version, exact accepted request/proof, original source PID,
  plan and publication heads. Atomically append the actual source publication,
  retain the disposal proof and tombstone the unbooted child without fabricating
  a Machine or BranchCompletion. Release only its ordinary reservation. Extra
  backing and its source dependency stay charged until separate typed retirement.
  The distinct disposal_pending/disposed states and selective v37 require all
  readers/projectors to upgrade; older envelopes cannot carry these semantics.
  Run NativeUnbootedBranchDisposalContract against each real adapter. Public
  native admission stays disabled; Backend/Runtime routing remains pending.

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
  @callback machine(context(), :claim, [
              SmolBox.ManagedMachine.key() | String.t() | non_neg_integer()
            ]) ::
              machine_result()
  @callback machine(
              context(),
              :claim_version,
              [SmolBox.ManagedMachine.key() | String.t() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :write,
              [SmolBox.ManagedMachine.key() | guard() | machine_changes() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :reserve,
              [
                ManagedMachine.key()
                | guard()
                | allocation()
                | non_neg_integer()
              ]
            ) :: machine_result()
  @callback machine(
              context(),
              :request,
              [SmolBox.ManagedMachine.key() | machine_action() | non_neg_integer()]
            ) :: machine_result()
  @callback machine(
              context(),
              :submit,
              [SmolBox.ManagedMachine.key() | Execution.t() | non_neg_integer()]
            ) :: result()
  @callback machine(context(), :finish, [Execution.key() | guard() | non_neg_integer()]) ::
              result()
  @callback machine(
              context(),
              :resolve,
              [SmolBox.ManagedMachine.key() | guard() | machine_resolution() | non_neg_integer()]
            ) :: machine_result()
  @type export_changes :: [
          state:
            :dispatching
            | :verifying
            | :completed
            | :published
            | :failed
            | :cancelled
            | :unknown
            | :resolved_unknown,
          receipt: SmolBox.ExportReceipt.t(),
          result: SmolBox.ExportResult.t(),
          error: Error.t(),
          resolved_at_ms: non_neg_integer()
        ]
  @callback machine(context(), :export_accept, [
              ManagedMachine.key()
              | SmolBox.ExportSpec.t()
              | String.t()
              | capacity()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :export_advance, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.Export.state()
              | export_changes()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :export_cancel, [
              ManagedMachine.key() | String.t() | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :export_resolve, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | machine_resolution()
              | non_neg_integer()
            ]) :: machine_result()
  @type capture_changes :: [
          state: SmolBox.CheckpointCapture.state(),
          result: SmolBox.CheckpointResult.t(),
          error: Error.t(),
          resolved_at_ms: non_neg_integer()
        ]
  @callback machine(context(), :capture_accept, [
              ManagedMachine.key()
              | SmolBox.CheckpointCaptureSpec.t()
              | String.t()
              | capacity()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :capture_advance, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.CheckpointCapture.state()
              | capture_changes()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :capture_cancel, [
              ManagedMachine.key() | String.t() | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :capture_resolve, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | machine_resolution()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :capture_release, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | non_neg_integer()
              | SmolBox.Embedded.NativeCaptureCleanup.t()
            ]) :: machine_result()
  @type branch_change ::
          :dispatching
          | :unknown
          | :failed
          | :cancelled
          | {:observed, SmolBox.Machine.t()}
          | {:complete, SmolBox.Machine.t()}
          | {:native_complete, SmolBox.Embedded.NativeBranchResult.t()}
          | {:native_complete, SmolBox.Embedded.NativeBranchReleaseResult.t()}
          | {:accept_partial_disposal, pos_integer(), String.t()}
          | {:accept_partial_disposal_cleanup, pos_integer(), String.t()}
          | {:accept_partial_collection, pos_integer(), String.t()}
          | {:complete_partial_collection,
             SmolBox.Embedded.NativePartialBranchCollectionResult.t()}
  @callback machine(context(), :branch_accept, [
              ManagedMachine.key()
              | SmolBox.BranchSpec.t()
              | String.t()
              | capacity()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_advance, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.Branch.state()
              | branch_change()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_resolve, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.Machine.t()
              | SmolBox.Embedded.NativeBranchResult.t()
              | SmolBox.Embedded.NativeBranchReleaseResult.t()
              | SmolBox.Embedded.NativePreparedBranchRetirementResult.t()
              | SmolBox.Embedded.NativeUnbootedBranchDisposalResult.t()
              | SmolBox.Embedded.NativePartialBranchDisposalResult.t()
              | SmolBox.Embedded.NativePartialBranchCleanupResult.t()
              | SmolBox.Embedded.NativePartialBranchCleanupResolutionResult.t()
              | :absent
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_retire, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.Embedded.BranchChildAbsence.t()
              | SmolBox.Embedded.UnbootedBranchChildAbsence.t()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_release, [
              ManagedMachine.key() | pos_integer() | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_release_advance, [
              ManagedMachine.key()
              | guard()
              | SmolBox.Branch.state()
              | branch_change()
              | non_neg_integer()
            ]) :: machine_result()

  @callback machine(context(), :branch_backing_accept, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | pos_integer()
              | boolean()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_delete_action_accept, [
              ManagedMachine.key() | guard() | :collect | :continue | :cleanup | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_delete_action_complete, [
              ManagedMachine.key()
              | guard()
              | :collect
              | :continue
              | :cleanup
              | SmolBox.Embedded.BranchDeletionCollection.t()
              | SmolBox.Embedded.BranchDeletionContinuation.t()
              | SmolBox.Embedded.BranchDeletionResolution.t()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_delete_accept, [
              ManagedMachine.key() | guard() | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :branch_release_storage, [
              ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.Embedded.BranchBackingRelease.t()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :expansion_accept, [
              SmolBox.ManagedMachine.key()
              | String.t()
              | pos_integer()
              | SmolBox.DiskExpansion.targets()
              | capacity()
              | non_neg_integer()
            ]) :: machine_result()
  @callback machine(context(), :expansion_advance, [
              SmolBox.ManagedMachine.key()
              | guard()
              | String.t()
              | SmolBox.DiskExpansion.state()
              | SmolBox.DiskExpansion.outcome()
              | non_neg_integer()
            ]) :: machine_result()
  @optional_callbacks machine: 3

  @doc """
  Optional durable worker admission state (`worker_control: 1`). Return the
  implicit active version-zero record only for a confirmed absent control row.
  Unavailable/corrupt storage must return an error. Never expire or delete modes.
  """
  @callback worker_control(context(), String.t()) ::
              {:ok, SmolBox.WorkerControl.t()} | {:error, Error.t()}

  @doc """
  Atomically change worker admission mode. Serialize this transaction with every
  disposable/managed reservation, branch creation, disk expansion and new capture/export admission.
  `:any` is permitted only for draining. Resume requires the observed version;
  retries of the last identical versioned request return the stored result.
  Duplicate existing admissions still deduplicate while draining. Existing
  assignments, commands, lifecycle operations and cleanup may continue.

  All controllers and adapters sharing the worker must enforce this contract.
  Mixed old writers bypass the gate and are unsupported. No worker request is
  fenced by this transaction. Run WorkerControlContract for each adapter.
  """
  @callback set_worker_mode(
              context(),
              String.t(),
              SmolBox.WorkerControl.mode(),
              non_neg_integer() | :any,
              non_neg_integer()
            ) ::
              {:ok, SmolBox.WorkerControl.t()} | {:error, Error.t()}

  @doc """
  Store-consistent bounded maintenance page across scopes. In the same snapshot,
  read control, total resource accounting and remaining assignments ordered by
  `{kind, scope, id}` (execution=0, machine=1). Include assigned records for which
  `WorkerMaintenance.relevant?/1` is true, including tombstones retaining resources.
  Return redacted entries; never command data or credentials. The supplied `now`
  stamps the report, not the freshness of worker observations. Errors are not empty
  inventories. Each page is separate; no result establishes worker quiescence.
  """
  @callback worker_maintenance(
              context(),
              String.t(),
              SmolBox.WorkerMaintenance.cursor(),
              pos_integer(),
              non_neg_integer()
            ) ::
              {:ok, SmolBox.WorkerMaintenance.t()} | {:error, Error.t()}
  @optional_callbacks worker_control: 2, set_worker_mode: 5, worker_maintenance: 5

  @doc "Atomically deduplicate volume identity and reserve worker disk budget, serialized with drain and every other admission."
  @callback volume_accept(context(), SmolBox.Volume.t(), capacity()) ::
              {:ok, SmolBox.Volume.t(), :inserted | :existing} | {:error, Error.t()}
  @doc "Fetch a volume including its retained tombstone. Missing and unavailable are distinct."
  @callback volume_fetch(context(), SmolBox.Volume.key()) ::
              {:ok, SmolBox.Volume.t()} | {:error, Error.t()}
  @doc "List a scoped page of volumes including deleted identities."
  @callback volume_list(context(), String.t(), String.t() | nil, pos_integer()) ::
              {:ok, [SmolBox.Volume.t()], String.t() | nil} | {:error, Error.t()}
  @type volume_action ::
          :delete
          | :resolve_delete
          | {:complete, :ready | :deleted}
          | {:complete_native, map()}
          | {:unknown, Error.t()}
  @doc "Compare-and-set a volume lifecycle transition. Never delete an attached volume; attachment is atomic with machine acceptance and released only on verified deletion."
  @callback volume_change(
              context(),
              SmolBox.Volume.key(),
              pos_integer(),
              volume_action(),
              non_neg_integer()
            ) :: {:ok, SmolBox.Volume.t(), :changed | :existing} | {:error, Error.t()}
  @optional_callbacks volume_accept: 3, volume_fetch: 2, volume_list: 4, volume_change: 5

  @callback capabilities(context()) ::
              {:ok, %{schema: 1, durable: boolean(), atomic: true}} | {:error, Error.t()}

  @doc """
  Atomically enroll a stable worker ID as HTTP or an embedded data domain.

  Advertise `backend_bindings: 1` only after implementing this callback and native
  allocation transactions. Serialize enrollment with every assignment admission.
  Legacy assignments imply HTTP. Reject kind/domain changes while any assignments,
  reservations or tombstones remain, and reject another target using the same
  embedded domain generation. Repeated enrollment of the same binding is harmless.
  Changing an empty target additionally requires controller/native quiescence.

  Native `reserve` allocations append a validated `Backend.Assignment` to the
  existing three-element tuple. Save that immutable intent with capacity and name
  assignment in one transaction, before any helper send. Reject native allocation
  without an identical enrolled binding and HTTP allocation on a native target.
  Retained command attachment inherits the assignment and takes no new reservation.
  Upgrade every controller, codec reader and projection writer before enrollment.
  For protocol-2 targets, additionally advertise `native_material_proofs: 2`
  only after supporting the selective v17 assignment/material-proof codec and
  its authenticated reservation/recovery projections. A v16-only authority can
  continue serving legacy targets; it cannot enroll a protocol-2 target merely
  because it advertises backend binding/recovery version 1.
  A package declaring `background_exec: 1` also requires
  `native_background_launches: 1`, after every native v17 assignment/launch reader
  and command-slot transaction supports that combination. HTTP launch records
  keep their existing envelopes; this is an additional native admission gate.
  A package declaring `terminals: 1` requires `native_terminal_sessions: 1`
  after every reader and command-slot transaction accepts retained Terminal.Spec/
  Terminal.Result under authenticated v17 material authority. The existing
  `interactive_terminal: 1` and `extended_execution: 1` markers remain required
  for terminal submission. No connection, input or transcript is persisted, and
  a surviving record never permits reconnect or input replay.
  Future native remote_sources/images descriptors additionally require
  native_sources: 1 after every reader accepts selective v19 OCI creation and
  retained image-pull authority. Preserve registry_sources: 1 atomic source
  reservations and managed_images: 1 image transactions as appropriate. Existing
  HTTP v10 and native v16-v18 records keep their encodings. This reader marker
  does not enable an unimplemented helper feature or grant source approval.
  A future native checkpoints descriptor additionally requires
  native_checkpoint_sources: 1 after every reader accepts selective v22
  checkpoint restore-source assignments and every atomic reservation writer
  preserves their original capture profile and creation identity. This marker
  does not enable capture histories, restore replay or public checkpoint admission.
  Checkpoint-capable native packages also require native_checkpointable: 1 after
  every reader accepts selective v23 creation opt-in and every reservation writer
  retains that marker for the original machine and its attached commands.
  """
  @callback bind_backend(context(), String.t(), :http | SmolBox.Backend.Binding.t()) ::
              {:ok, :http | SmolBox.Backend.Binding.t()} | {:error, Error.t()}
  @optional_callbacks bind_backend: 3

  @typedoc "Opaque keyset position in the authority's complete assignment scan."
  @type backend_cursor :: {0 | 1 | 2, String.t(), String.t()} | nil

  @doc """
  Return a bounded page of authenticated assignments for a worker, including
  released/deleted tombstones and retained command records.

  Advertise `backend_recovery: 1` only after implementing this callback. Authenticate
  payloads and all projections, including records with missing or displaced worker
  projections. An indexed worker query alone can silently omit corrupt evidence.
  A complete authority scan may return an empty page with a non-nil next cursor;
  callers must follow it. Limit is 1–100, and returned records never exceed it.
  Cursor order is `{kind, scope, id}`, where kind is execution=0, machine=1,
  volume=2. Nil starts or ends the scan. Unassigned records and other workers may
  advance the cursor but must not appear in the returned page.

  Each page is consistent, but multiple pages are not a snapshot. The controller
  must establish native dispatch quiescence and renew its worker lease before
  using a complete scan to activate a fresh helper. Reads never claim, mutate,
  release capacity or mint ownership. Corrupt/unavailable/unknown-schema data
  fails closed with an error, not an empty page. Upgrade all shared readers first.
  """
  @callback backend_assignments(context(), String.t(), backend_cursor(), pos_integer()) ::
              {:ok, [Execution.t() | ManagedMachine.t() | SmolBox.Volume.t()], backend_cursor()}
              | {:error, Error.t()}
  @optional_callbacks backend_assignments: 4

  @type allocation ::
          {String.t(), String.t(), capacity()}
          | {String.t(), String.t(), capacity(), SmolBox.Backend.Assignment.t()}
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
              allocation(),
              non_neg_integer()
            ) :: result()
  @callback release(context(), Execution.key(), guard(), non_neg_integer()) :: result()
  @callback cancel(context(), Execution.key(), non_neg_integer()) :: result()
  @callback due(context(), non_neg_integer(), cursor(), pos_integer()) ::
              {:ok, [Execution.t()], cursor()} | {:error, Error.t()}
  @callback usage(context(), String.t()) :: {:ok, resources()} | {:error, Error.t()}
end
