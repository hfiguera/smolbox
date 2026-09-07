# Persistence and recovery contract

Use a durable store when executions must survive an application restart. SmolBox
persists intent and observations; the host adapter supplies transactions and
durability. The included PostgreSQL example has real database and process-recovery
coverage on Linux and macOS. Production hostile-workload qualification is outside
the first-release scope. See [Compatibility](compatibility.md) for recorded evidence
and [Troubleshooting](troubleshooting.md) for common operational symptoms.

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

Fencing prevents stale **store writes**, not HTTP already sent to SmolVM. A
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
[`test/support/store/contract.ex`](https://github.com/hfiguera/smolbox/blob/v0.1.0-rc.1/test/support/store/contract.ex).
It is repository test support, not part of the published library package. An adapter test module
uses `SmolBox.Store.Contract` and supplies `adapter` and `store` in its setup
context. It checks concurrent acceptance, conflicts, claims and CAS races, atomic
reservations, release conditions, worker takeover, expiry, and due pagination.
The suite alone does not certify durability; also run fresh-process database
recovery, unavailable-database, corruption, and transaction-failure tests.

The repository's
[durable host example](https://github.com/hfiguera/smolbox/tree/v0.1.0-rc.1/examples/durable_host)
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

An API-server restart is not a VM restart. SmolVM 1.14.1 keeps VMs running when
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
