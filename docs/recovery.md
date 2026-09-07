# Persistence and recovery contract

The store behaviour, versioned execution records, bounded memory adapter, and
shared adapter tests are implemented. The host-owned Ecto/Postgres example passes
real database conformance and fresh-process reads. The supervised managed runtime
is still under implementation. No automatic recovery service is released.

`SmolBox.Store` defines atomic acceptance, authoritative lookup, worker leases,
execution claims, compare-and-swap writes, reservations, release, cancellation
intent, resource inspection, and bounded due-work scans. A host adapter owns its
database, migrations, credentials, encryption, availability, and retention.
The core package has no database dependency and never runs host migrations.

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

The reusable suite is in `test/support/store/contract.ex`. An adapter test module
uses `SmolBox.Store.Contract` and supplies `adapter` and `store` in its setup
context. It checks concurrent acceptance, conflicts, claims and CAS races, atomic
reservations, release conditions, worker takeover, expiry, and due pagination.
The suite alone does not certify durability; also run fresh-process database
recovery, unavailable-database, corruption, and transaction-failure tests.

The repository example at `examples/durable_host` owns its Repo, schema migration,
AES-256-GCM record encryption, and indexed projections. Mutations serialize on a
partition row inside a SQL transaction. It demonstrates a small-pool adapter,
not automatic database provisioning, key rotation, or unlimited throughput. See
its README for configuration, schema upgrades, keys, and retention responsibilities.
