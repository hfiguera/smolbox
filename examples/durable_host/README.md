# Durable host example

This standalone host owns an Ecto Repo and a PostgreSQL implementation of
`SmolBox.Store`. It has no Keel, Jido, or Phoenix dependency. It currently
exercises persistence; the managed command demonstration is added with the
runtime implementation.

Use the package's pinned Elixir/OTP toolchain. From this directory, configure
`DATABASE_URL` for a disposable PostgreSQL database, then run:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix test --warnings-as-errors
MIX_ENV=test mix dialyzer
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

The current SQL migration and record codec are schema version 1. Unknown or
corrupt payload versions fail closed. Apply migrations before starting a managed
runtime. An upgrade must back up records, preserve keys and immutable identities,
and migrate payloads and index projections together under host-controlled
maintenance. This example does not silently reinterpret future schemas or fall
back to memory when PostgreSQL is unavailable.
