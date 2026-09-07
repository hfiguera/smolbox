# Durable host example

This standalone host owns an Ecto Repo and a PostgreSQL implementation of
`SmolBox.Store`. It has no Keel, Jido, or Phoenix dependency. It includes a managed
Python execution demonstration and a real-worker process-kill recovery suite.
Shared example setup lives in `../support/lib`; fault-test helpers are compiled
only in the test environment from the repository's `test/support/fault` directory.

Use the package's pinned Elixir/OTP toolchain. From this directory, configure
`DATABASE_URL` for a disposable PostgreSQL database, then run:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix test --warnings-as-errors
MIX_ENV=test mix dialyzer --force-check
MIX_ENV=test mix hex.audit
MIX_ENV=test mix deps.audit
```

Alternatively set `SMOLBOX_DATABASE_SOCKET_DIR` for a local PostgreSQL Unix
socket. Socket defaults are port 25432, user `smolbox`, and database
`smolbox_contract`; override them with `SMOLBOX_DATABASE_PORT`,
`SMOLBOX_DATABASE_USER`, and `SMOLBOX_DATABASE_NAME`. Missing configuration fails
startup. No database is created, no migrations are run, and no sandbox is
contacted automatically. Use verified database TLS when crossing a trust boundary;
configure that in the host Repo according to the deployment's CA policy.

The tests create random isolated partitions and delete only those partitions.
They run the shared store conformance suite against real SQL transactions, then
check authenticated payloads, corrupt index projections, rollback, and reads
from a fresh BEAM process. A separate outage probe must run with the test
database actually unavailable:

```sh
MIX_ENV=test mix run --no-start --no-compile scripts/check_unavailable.exs
```

CI stops only its disposable service container, runs this probe, and restarts
that container. Do not stop a shared database to run it.

The outage probe also attempts managed runtime startup and requires a typed store
error. Example Dialyzer commands use `--force-check` because SmolBox's path
dependency can change while the example lockfile stays the same.

## Managed execution and process recovery

Configure the worker, pinned Python artifact, private object directory,
fingerprint key file, and execution ID described in `../minimal_host/README.md`.
Also provide a stable `SMOLBOX_STORE_PARTITION` and
`SMOLBOX_ENCRYPTION_KEY_FILE` pointing to a different private 32-byte key. Apply
the migration first, then run:

```sh
MIX_ENV=test mix run scripts/demo.exs
```

The host submits a Python command, verifies its binary outputs and test marker,
then prints the recorded outcome after cleanup releases capacity. Repeating the
same identity with the same spec returns the existing outcome. Keep the partition,
both keys, artifact catalog and object directory stable across restarts. Changing
the spec under that identity fails instead of running a new command.

To demonstrate cancellation, use a new identity and set both
`SMOLBOX_EXAMPLE_WAIT=true` and `SMOLBOX_EXAMPLE_CANCEL=true`. The command result
may remain unknown after termination and deletion. The real retention interval
is intentional and is not shortened by the example's observer timeout.

Run the separate process-kill suite only against a dedicated, otherwise idle
worker and disposable PostgreSQL database:

```sh
MIX_ENV=test mix test test/recovery_runtime_test.exs \
  --include runtime --trace --warnings-as-errors
```

Explicit selection requires `SMOLBOX_RUNTIME_URL`, `SMOLBOX_PYTHON_ARTIFACT`, and
`SMOLBOX_PYTHON_SHA256`; missing values fail. These tests are excluded from the
ordinary store suite, which still uses a real database. Each runtime case creates
a private directory, independent secret keys and a SQL partition, launches a real
child BEAM, waits for a named boundary, sends SIGKILL to that owned process, and
launches a fresh BEAM with the original durable identity. Cases run serially and
wait through the real retention deadline when the outcome is uncertain.

The test's trusted host ledger counts client dispatch attempts, not worker
acceptance receipts. No-replay assertions combine that ledger, durable identity,
persisted result or uncertainty, guest test outputs when available, and observed
machine absence before capacity release. The ledger is test instrumentation and
does not change SmolBox's production guarantee.

On success, tests remove only their own SQL partition and private files. On a
failure they retain evidence and stop only a machine matching its recorded
creation evidence. They do not sweep names or delete an unverified machine.
Inspect retained resources before retrying. Real restart tests do not establish
hard host resource quotas or fence already accepted upstream requests.

## Host integration and security

Construct `SmolBox.DurableHost.Store.new(Repo, partition, encryption_key)` with a
stable partition and a **32-byte secret key from host secret storage**. Keep this
key distinct from SmolBox's execution-fingerprint key. The tests generate keys
only for disposable partitions; generating a new key on every application start
would make existing records unreadable. Worker proxy credentials live in worker
configuration and are never copied into stored execution records.

Each payload uses versioned AES-256-GCM with a random nonce and authenticated
partition/scope/execution identity. Index fields are checked against the decrypted
record on reads. Command environment and stdin may contain secrets, so restrict
database access, backups, and key access. Encryption is not permission to expose
this adapter as a public endpoint. The database, schema, and index maintenance
remain trusted host infrastructure. SQL values are bound parameters and query
logging is disabled. API errors exclude exception details and payload bytes.

All mutations lock one partition row inside a transaction. That deliberately
serializes writes to make claims, capacity, and identity atomic for a small worker
pool. Indexed due scans use bounded keyset pages; completed identities remain
queryable. This example has no automatic purge, storage quota, key rotation, or
online schema migration service. Monitor database size and archive records under
an explicit identity-retention policy. Deleting an identity permits that ID to be
accepted again, so do not treat deletion as ordinary cleanup.

One physical worker must have one stable worker ID and one store partition across
controllers. Changing the partition is not controller takeover. Leases fence
store writes; they cannot retract worker HTTP requests.

The record codec remains schema version 1. A second SQL migration adds
`smolbox_machine_identities` for bounded worker/name lookup, with a unique
assignment per worker/name and per execution. Reservation writes this index in
the same transaction as the encrypted execution record; cleanup retains it.

For an existing example database, stop its controllers, apply migrations, and
backfill each partition using that partition's original encryption key:

```sh
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix run scripts/backfill_machine_index.exs \
  the_partition /absolute/private/encryption.key 100
```

Each transaction reads and authenticates one existing record before inserting
its assignment. The command performs at most the supplied number of steps
(1..10000). `machine-index:more` exits with code 2 and means another invocation
is needed; `machine-index:done` means the partition is indexed. Wrong keys and
conflicting assignments fail without rewriting records. Runtime startup and
machine lookup reject incomplete indexes. Check every partition before restarting
controllers. A fresh database has no backfill work. SQL index maintenance remains
trusted infrastructure; this is not protection against a hostile database owner.

Unknown or corrupt payload versions fail closed. Apply migrations before starting a managed
runtime. An upgrade must back up records, preserve keys and immutable identities,
and migrate payloads and index projections together under host-controlled
maintenance. This example does not silently reinterpret future schemas or fall
back to memory when PostgreSQL is unavailable.
