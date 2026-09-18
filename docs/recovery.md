# Persistence and recovery contract

Use a durable store when executions must survive an application restart. SmolBox
persists intent and observations; the host adapter supplies transactions and
durability. The included PostgreSQL example has real database and process-recovery
coverage on Linux and macOS. A subsequent
[constrained Linux deployment](resource-qualification.md#subsequent-linux-deployment-validation)
also passed worker OOM, database-outage and independent worker-deadline tests.
Those tests preserved execution identity and unknown outcomes without replay,
retaining capacity until owned absence was verified. They do not add execution
fencing to the upstream API or change the recovery contract below. See
[Compatibility](compatibility.md) for recorded evidence and
[Troubleshooting](troubleshooting.md) for common operational symptoms.

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
[`test/support/store/contract.ex`](https://github.com/hfiguera/smolbox/blob/v0.1.4/test/support/store/contract.ex).
It is repository test support, not part of the published library package. An adapter test module
uses `SmolBox.Store.Contract` and supplies `adapter` and `store` in its setup
context. It checks concurrent acceptance, conflicts, claims and CAS races, atomic
reservations, release conditions, worker takeover, expiry, and due pagination.
The suite alone does not certify durability; also run fresh-process database
recovery, unavailable-database, corruption, and transaction-failure tests.

The repository's
[durable host example](https://github.com/hfiguera/smolbox/tree/v0.1.4/examples/durable_host)
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

## Upgrading to 0.1.4

SmolBox 0.1.4 changes the default worker from smolvm 1.16.0 to **1.16.1**.
Updating the Elixir dependency does not install or upgrade that worker. Before
updating an application, choose one of these paths:

- Retain an existing worker by setting `runtime_version: "1.16.0"` explicitly
  in every controller that owns it. Explicit 1.14.6 and 1.14.1 offline workers
  remain supported too.
- Upgrade the worker using the [drain and verification procedure](host-integration.md#upgrading-a-worker).
  Resolve existing work and preserve its state before replacing the complete
  runtime distribution. Configure every owner to expect 1.16.1 and verify an
  owned execution through cleanup before resuming submissions.

Version checks require an exact match; there is no automatic fallback.
Controlled networking works with 1.16.0 and 1.16.1 and remains offline by default.

There is **no additional record schema migration from 0.1.3**: both versions read
v1 records and write v2. Applications coming from 0.1.2 or earlier must also
complete [the coordinated record upgrade below](#upgrading-to-0-1-3).

Managed cleanup now separates disposal from preservation, as described in
[Preservation and disposal](#preservation-and-disposal). Completed work can
remove its owned machine without a preliminary graceful stop. Unknown work still
retains its disks and reservation during its retention period. A failed graceful
stop never automatically authorizes deletion, and retry exhaustion may still
require operator resolution. Upgrading does not reset exhausted cleanup budgets
or replay commands with uncertain outcomes.

## Upgrading to 0.1.3

SmolBox 0.1.3 introduces record schema v2 to persist network policies. Despite the
patch version number, this is a deployment compatibility change for applications
using `SmolBox.Store.Codec`, including the PostgreSQL example. A **controller** is
an Elixir application instance running SmolBox, not a smolvm worker.

| Reader | Legacy v1 records | New v2 records |
|---|---|---|
| SmolBox 0.1.2 | Supported | Rejected |
| SmolBox 0.1.3 and 0.1.4 | Supported as offline | Supported |

**Every new codec write uses v2, even when networking stays offline.** Reading a
valid v1 record adds offline defaults in memory without changing its execution
fingerprint or immediately rewriting the stored bytes. Its next save uses v2.
Upgrading the SQL schema alone cannot make an old reader understand those bytes.
Custom adapters with their own serialization need an equivalent migration plan.

For controllers sharing a durable store:

1. Pause new submissions and drain active work, including collection, cleanup
   and reservation release. Resolve retained or unknown work through the existing
   recovery procedure; do not delete its records to make the upgrade proceed.
2. Stop every old controller and any other process reading or writing these
   records. Do not leave 0.1.2 instances running during a rolling deployment.
3. Back up durable data and preserve the existing fingerprint key, encryption
   configuration, execution identities and worker ownership information.
4. Deploy 0.1.3 to all readers and writers. Its default worker version is 1.16.0;
   follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker)
   or explicitly keep `runtime_version: "1.14.6"` or `"1.14.1"` for older workers.
   The library does not install or upgrade smolvm. Network policies require 1.16.0.
5. Verify existing records remain readable and duplicates retain their identity.
   Resume submissions after confirming the configured workers pass version checks
   and recovery is operating with the same durable state and keys.

**Rollback:** before any v2 record is written, the record format does not prevent
returning to 0.1.2, provided its worker configuration is still compatible. After
v2 writes, there is no built-in downgrade to v1. Keep a compatible reader or plan
an explicit, reviewed migration. Simply restoring an earlier database backup can
lose evidence of commands already accepted by workers and lead to duplicate work.
A decoding failure must remain an error, never be treated as a missing execution.

The in-memory store is ephemeral and is not a persistence migration strategy.
Restarting it loses execution records and may leave machines behind. Applications
using only `SmolBox.Client` do not use this managed record format, but must still
check their worker version and any persistence they own.
