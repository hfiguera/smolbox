# Persistence and recovery contract

Use a durable store when execution records must survive an application restart.
SmolBox records intent and observations; your store adapter supplies transactions
and durability. A restart can resume observation and cleanup, but it cannot turn
an unknown command outcome into a known one.

The same no-replay rule applies to uncertain registry preparation and image pulls.
Preserve the source identity and original operation handle; follow
[registry recovery](images-and-registry-artifacts.md#recovery-and-resource-accounting)
before resolving them. A cache hit, expired lease or observed absence cannot
cancel a request already sent to the worker.

For an existing deployment, follow [Upgrading SmolBox](upgrading.md). See
[Troubleshooting](troubleshooting.md) for common symptoms and
[Testing reports](testing.md) for the recorded recovery checks.

<a id="retained-machines-0-2-0"></a>

## Retained machines

`SmolBox.Machines` adds machine ownership independent of executions. Its commands
retain the VM and hold one exclusive command slot through preparation, execution,
and collection. Cancellation and unknown outcomes never authorize automatic
machine deletion. See [Managed persistent machines](persistent-machines.md) for
operator quiescence and explicit absence resolution. The disposal and unknown
retention rules below describe **disposable** executions.

## Checkpoint execution

Checkpoint executions preserve the same identity, uncertain-outcome and cleanup
rules described below. Keep approvals pinned to the original capture runtime and
platform. See [Checkpoint execution](checkpoints.md) for source approval.

## Store contract

`SmolBox.Store` defines atomic acceptance, authoritative lookup, worker leases,
execution claims, compare-and-swap writes, reservations, release, cancellation
intent, resource inspection, and bounded due-work scans. A host adapter owns its
database, migrations, credentials, encryption, availability, and retention.
The core package has no database dependency and never runs host migrations.

## Identity, claims, and replay

An execution key is `{scope, execution_id}`. Acceptance stores the immutable spec
and keyed fingerprint before any worker action. Identical duplicates return the
original record, including its deadline, outcome and cleanup status. Conflicting
fingerprints fail. A store timeout or lost commit acknowledgment must never be
translated into absence; inspect or resubmit the same identity through atomic
acceptance. The host must use a stable fingerprint key across restarts.

Worker ownership and execution claims are distinct. Both have bounded leases;
expired takeover increments their generations. Writes check the record version,
claim generation, owner, and the current worker generation. Renewing a worker
after expiry does not automatically revive an execution's old fence. Claims must
be refreshed before dispatch intent can be committed.

Fencing prevents stale **store writes**, not HTTP already sent to smolvm. A
replacement controller cannot replay dispatching, running, or unknown work.
The selected worker API has no durable command receipt. An uncertain operation
can remain unknown indefinitely even after its VM is confirmed stopped or absent.
Only the host can authorize a distinct execution attempt under a new identity.

## Outcomes and deadlines

Execution, collection and cleanup remain separate. Nonzero exit is an observed
result. Failed output collection cannot erase it, and failed cleanup cannot turn
it into a failed command. Error history retains the latest eight redacted entries.
Creation evidence and observed results become immutable once recorded. Cleanup
completion after worker assignment requires recorded absence; capacity release
then occurs through a separate atomic store operation. Unknown work and failed
cleanup retain CPU, memory, disk and slot reservations until release is justified.

Absolute queue and stage deadlines survive reloads. First entry sets preparation,
execution, collection, and cleanup budgets; repeated inspection never resets
them. Due queries use bounded pages ordered by `{next_due_at_ms, scope, id}`.
Records remain the authority when observers, callers or mailboxes disappear.

## Preservation and disposal

Managed cleanup chooses an operation from the persisted execution state:

- After execution and collection have finished, it deletes the verified owned
  machine directly. Failed preparation before dispatch is also eligible for
  disposal. No graceful stop is required for disks that will be discarded.
- While an unknown execution remains within its retention window, it attempts a
  graceful stop, reinspects identity and stopped state, and preserves the disks.
  A failed stop does not authorize deletion or establish termination.
- After unknown retention expires, a cleanup attempt with remaining mutation
  budget may delete the verified machine directly. Absence can establish
  termination, but cannot recover the command's exit status.

This is a choice made before mutation, not a delete fallback after any stop error.
All disposal paths still require creation evidence and a matching observed
incarnation. Successful DELETE responses must be followed by an absence check;
only recorded absence permits reservation release. Output collection finishes or
records its failure before a known execution becomes eligible for disposal.

The low-level `SmolBox.Client.stop/2` remains a graceful stop. On smolvm 1.16.1,
filesystem synchronization failure deliberately leaves a VM alive. That behavior
is appropriate when disks must be preserved, but is not a prerequisite for
explicit disposal. Bounded stop retries can still be exhausted during retention;
expiry does not reset their budget. Such unresolved machines remain charged and
require operator resolution as described below.

## Storage adapters

`SmolBox.Store.Memory` is explicitly ephemeral. A process/VM restart loses its
records and can leave machines behind. It bounds record count and encoded record
bytes and retains completed identities, so it eventually rejects new records
when full. These bounds are not claims about total BEAM RSS. Never silently fall
back to it from a durable adapter.

`SmolBox.Store.Codec` is a versioned format for **trusted host storage**, not a
public or guest input format. It rejects compressed terms, trailing bytes,
unrecognized schemas, unsafe data shapes, and live BEAM values. It loads only the
fixed schema vocabulary before safe decoding in a fresh BEAM. The codec does not
encrypt secrets: adapters must authenticate and encrypt payloads or use an
explicitly approved equivalent storage policy. Unknown-schema or corrupt rows
are errors requiring migration or investigation, never permission to start over.

The reusable suite is in
[`test/support/store/contract.ex`](https://github.com/hfiguera/smolbox/blob/v0.3.0/test/support/store/contract.ex).
It is repository test support, not part of the published library package. An adapter test module
uses `SmolBox.Store.Contract` and supplies `adapter` and `store` in its setup
context. It checks concurrent acceptance, conflicts, claims and CAS races, atomic
reservations, release conditions, worker takeover, expiry, and due pagination.
The suite alone does not certify durability; also run fresh-process database
recovery, unavailable-database, corruption, and transaction-failure tests.

The repository's
[durable host example](https://github.com/hfiguera/smolbox/tree/v0.3.0/examples/durable_host)
owns its Repo, schema migration,
AES-256-GCM record encryption, and indexed projections. Mutations serialize on a
partition row inside a SQL transaction. It demonstrates a small-pool adapter,
not automatic database provisioning, key rotation, or unlimited throughput. See
its README for configuration, schema upgrades, keys, and retention responsibilities.

## Machine ownership and assignment lookup

A missing machine can be only a temporary observation while an old create request
is still in flight. Managed recovery therefore never releases an assigned
reservation without persisted creation evidence merely because a lookup returns
404. Likewise, stopping a VM does not fence a delayed original exec request.
Unknown retained machines are rechecked; a reobserved running VM revokes current
termination evidence until another stop is confirmed. See the host integration
guide for the operator quiescence boundary and deadline limitations.

`find_machine/3` resolves a worker/name to its original execution through an
assignment index retained after cleanup. Reservation updates that index
atomically, preventing a second execution from taking the same worker/name.
The memory adapter bounds the index by its record count. The durable example's
second migration adds a unique SQL mapping and an explicit one-record-per-
transaction authenticated backfill. Missing backfill work blocks startup and
lookup until completed; see the example README for the maintenance procedure.
Worker inventory inspection remains read-only and never substitutes a matching
name for recorded creation evidence.

## Worker and output-store failures

An API-server restart is not a VM restart. smolvm 1.14.1 keeps VMs running when
`smolvm serve` exits. The dedicated qualification script kills its own server
after the durable controller records running work, waits for recorded uncertainty,
then restarts the server against the same worker data. It verifies the original
VM still runs before allowing recovery. Recovery keeps the execution identity,
deadline and unknown outcome, stops the verified VM, waits through retention,
deletes it, records absence, and releases capacity. This tests reconnection and
cleanup; it does not recover a command receipt or fence earlier worker requests.

Cleanup has a finite mutation budget. When the API remains unavailable beyond
that budget and the persisted cleanup deadline, recovery retains the unknown
outcome, cancellation intent and reservation. Reconnection alone does not reset
the budget or authorize more mutations. Bounded read-only reconciliation can
recognize absence after an operator resolves the verified resource and then
release capacity. Real probes keep the API down for approximately 95 seconds
to cross this boundary; the still-running VM requires operator cleanup.

An unavailable output store produces `:collection_failed` while preserving the
known command exit and allowing independent machine cleanup. Restoring storage
and resubmitting the same execution does not replay the command or silently
recollect deleted guest files. Cancellation racing with a received exit also
retains that exit: cancellation intent is not permission to replace observed
evidence with a fabricated cancelled result. Collection may finish or fail
depending on which file operations completed before cancellation was observed.

## Long commands and background launch

See [Long-running execution](long-running-exec.md) for coordinated codec-v6/store
upgrades, extended observation budgets and background launch recovery. A confirmed
launch is `:launched`, with a typed PID result; it does not prove readiness or
continued process life. Lost launch evidence stays unknown and must not be replayed.
Background processes can overlap later file operations. Stop/start requires an
explicit new service launch; cancellation does not perform PID-based termination.

## Interactive session recovery

Terminal executions use codec v7 and require `interactive_terminal: 1` plus
`extended_execution: 1`. Upgrade every controller, reader and adapter together;
retained v7 history prevents rollback to readers that do not understand it.
Live handles and sockets are not persisted. Recovery preserves confirmed exits
or unknown outcomes without opening another shell or replaying input. Unknown
sessions retain the machine's command slot and reservations.

Use [terminal recovery](interactive-terminals.md#recovering-after-controller-or-connection-loss)
and the existing explicit quiescent resolution procedure. An expired lease or
observed stop does not drain requests already sent to the worker. Upstream 1.17.0 and 1.19.0
can delete the disks of formerly running machines whose processes died when its
API restarts. If draining requires a worker restart, first record an ownership-verified
stop to preserve supported disks, then drain old requests and verify the final
stopped state before resolution. Missing disks are not recoverable through a new
PTY; never silently replace the missing machine.

## Startup workloads and console diagnostics

Workload machines use codec v8; ordinary records retain their earlier formats.
No SQL migration is added, but all shared readers/adapters must understand v8
before accepting workload intent. Tombstones retain the configuration, so deleting
a machine does not make old-reader rollback safe. Follow the
[workload upgrade procedure](workloads.md#persistence-and-upgrades). Console streams
have no durable cursor or transcript and cannot establish application readiness.

## Guest path policies and larger files

Expanded path/file profiles selectively use codec v9 and store capability
`guest_files: 1`. Upgrade every shared controller, reader and adapter before
allowing these writes; no SQL migration is required. Ordinary v1–v8 records load
with default paths and preserve their previous fingerprints/encodings. New policy
is immutable and retained in tombstones; deletion does not make rollback safe.
Recovery rechecks current worker approvals before file I/O. It cannot adopt a
broader policy or silently downgrade a file budget. Unknown command outcomes
remain blocked without replay. See [guest file recovery](guest-files.md#recovery-and-upgrades).

## Uncertain exports and helper cleanup

Managed exports persist their own intent and outcome. An unknown export keeps the
source operation slot and helper resources, even when the source looks stopped.
A verified `:published` result also keeps them: smolvm 1.19.0 may report publication
success without proving its helper terminated. Fence pending requests and establish
helper and staging quiescence before `SmolBox.Exports.resolve/4`. Never replay an
uncertain export or delete its registry artifacts as automatic cleanup. Follow the
[export recovery procedure](machine-exports.md#verify-cleanup-before-releasing-the-source).

## Managed checkpoint capture

[Managed checkpoints](managed-checkpoints.md) add explicit idle, offline bare-guest
capture and independent restore on 1.19.0. A captured result does not attest worker
quiescence; resolve only after fencing outstanding requests and confirming staging
cleanup. Checkpoint storage remains accounted for after source deletion until
explicit release. Opt-in machines/history use codec v12, requiring coordinated
reader and resource projection upgrades but no SQL migration.

## Managed branch dependencies

[Managed branches](managed-branches.md) create same-worker leaf children from idle,
offline bare sources on smolvm 1.19.0. They require `managed_branches: 1`, codec v13,
and atomic source/child admission. Upgrade all shared readers and resource projection
writers first; the PostgreSQL example needs no SQL migration. Retained v13 history
prevents rollback to an older reader even after machines are deleted.

A lost creation/release response is never replayed. Keeping an uncertain child needs
persisted creation evidence; a cleared held flag cannot prove release. Explicitly
retire deleted child dependencies before source lifecycle changes. Extra backing
capacity remains until source deletion, verified absence and host-confirmed file
cleanup through `Branches.release_storage/3`. Store fencing does not fence worker
requests already sent. Follow the guide's recovery procedure before asserting
quiescence or cleanup.

## Uncertain local volumes

Keep volume records and reservations when provisioning or deletion is uncertain.
Upstream has no volume observation/ownership-token API. SmolBox never adopts a
directory from its path, replays provisioning or silently creates empty data.
After fencing pending requests and releasing any machine attachment through the
normal verified deletion path, use `Volumes.resolve_delete/4` with the inspected
version and `quiesced: true`. This explicitly deletes storage; preserve needed data
first. A stopped observation or expired controller lease is not worker fencing.
See [local volume recovery](local-volumes.md#uncertain-outcomes-and-recovery).

## Earlier upgrades

For release transitions, use [Upgrading SmolBox](upgrading.md). These links retain
older bookmarks; the instructions are kept in the upgrade documentation.

## Upgrading to 0.2.0

Follow the [consolidated upgrade guide](upgrading-to-0.2.0.md) for worker selection,
controller quiescence, PostgreSQL migrations, capability/schema requirements and
rollback restrictions.

### Upgrading to 0.1.3

See [Upgrade to 0.1.3](upgrading-within-0.1.x.md#upgrading-to-0-1-3).

### Upgrading to 0.1.4

See [Upgrade to 0.1.4](upgrading-within-0.1.x.md#upgrading-to-0-1-4).

### Upgrading to 0.1.5

See [Upgrade to 0.1.5](upgrading-within-0.1.x.md#upgrading-to-0-1-5).

### Checkpoint records (0.1.5)

See [the checkpoint record transition](upgrading-within-0.1.x.md#upgrading-to-0-1-5).
