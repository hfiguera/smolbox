# Durable host example

This standalone host owns an Ecto Repo and a PostgreSQL implementation of
`SmolBox.Store`. It includes a managed Python execution demonstration and a
real-worker process-kill recovery suite.
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

For a separate API-server restart probe, use an otherwise idle worker data root
with **no server listening** on the selected loopback port. From the package root:

```sh
MIX_ENV=test python3 scripts/qualify_worker_restart.py \
  --smolvm /absolute/path/to/smolvm \
  --python /absolute/path/to/python.smolmachine \
  --report /absolute/path/to/worker-restart-report.json
```

Run through the pinned toolchain so the child `mix` command uses it too. Supply
the same database configuration as above; Linux additionally requires an explicit
dedicated `SMOLVM_DATA_DIR`. The script refuses an occupied port, starts and kills
only its own server/controller processes, and requires an initially empty worker
inventory. It uses the pinned 1.14.1 runtime, checks recorded creation evidence
before cleanup, and bounds its HTTP reads and child diagnostics. It retains its
private keys, object directory and SQL partition for inspection, including after
success. The JSON report identifies that workspace without exposing key bytes.
The worker server is stopped when the probe finishes; it never starts or stops
a pre-existing host service. The default `--scenario restart` takes about 67
seconds on the qualified hosts because it waits through the actual retention
window. Run it again with `--scenario unavailable` and `--scenario missing`, each
with its own report filename. Unavailability lasts beyond the stored cleanup
deadline; the probe verifies retained cancellation/accounting, then acts as the
operator to stop/delete only its recorded VM. The missing scenario deletes that
verified VM while the controller is paused and checks absence-based recovery.
Both retain an unknown result and require exactly one recorded dispatch attempt.

The runtime test file also contains an actual output-directory outage and two
cancellation races at SQL result commit. The outage moves only the test's private
object directory while collection is paused, then restores it in a finalizer.
It requires a known exit, failed collection, verified VM cleanup and no command
replay after runtime restart. The cancellation cases require the original intent
timestamp and observed exit to survive. These three tests use a real worker and
PostgreSQL alongside 20 fresh-BEAM interruption cases and two dispatcher-failure
cases that preserve execution progress before/after SQL result persistence.

## Opt-in durable benchmark

The benchmark uses this host's real PostgreSQL store, directory adapter and a
previously provisioned, initially idle SmolVM 1.14.1 worker. It provisions no
service, changes no host quotas and clears no image/page cache. Apply the example
migrations first. Use native approved artifacts, a new private object directory,
fresh 32-byte fingerprint/encryption key files and a unique store partition for
each trial. Keep the private settings and keys after failure so accepted records
can be inspected and recovered before another trial.

Create a mode-0600 JSON settings file using the following fields. Replace every
placeholder, including the measured hardware and database topology; zero memory
is deliberately invalid. The report path must not already exist.

```json
{
  "url": "http://127.0.0.1:19470",
  "artifact_path": "/private/catalog/python.smolmachine",
  "artifact_sha256": "verified-native-artifact-sha256",
  "artifact_root": "/private/new-trial/objects",
  "fingerprint_key_file": "/private/new-trial/fingerprint.key",
  "encryption_key_file": "/private/new-trial/encryption.key",
  "id": "unique-trial-id",
  "partition": "unique-trial-partition",
  "report": "/private/new-trial/report.json",
  "samples": 20,
  "hardware": {"cpu": "verified CPU model", "memory_bytes": 0},
  "database_topology": "describe the actual local or forwarded connection",
  "cache_context": "describe the existing worker/cache state; do not assume cold"
}
```

Run from this example with the normal database configuration and pinned toolchain:

```sh
MIX_ENV=test mix run scripts/benchmark.exs /absolute/path/to/settings.json
```

The default trial runs 20 sequential Python submissions, then fills four queue
positions while one VM is occupied and requires four excess submissions to be
rejected. It also measures a 512 KiB producer with a caller delayed by two seconds,
a preparation failure with no exec invocation, and cancellation after guest output
with an unknown outcome and retained reservation. It waits through the actual
retention window and confirms that all owned records release capacity and the
initially empty worker becomes empty again. Expect several minutes; do not run
another owner or database-fault test against these resources concurrently.

Reports include monotonic lifecycle request times, stage durations, queue waits,
observed outcome/cleanup times, bounded invocation counts and sampled memory.
Input verification downloads are distinguished from output collection. Transport
invocations are recorded before forwarding; a killed observer can have a start
with no completed request duration. Counts are client instrumentation, not worker
acceptance receipts. Telemetry must settle without drops/timeouts, and the metrics
table has a 5,000-row limit. Missing required evidence fails the trial.

Outcome polling has a 25 ms interval and cleanup polling 100 ms. Resource samples
are taken every 100 ms; they can miss peaks. Supervised-process statistics exclude
nested linked request tasks, while whole-BEAM memory also includes the Repo, HTTP
pools and benchmark instrumentation. Neither measures worker/host RSS or proves a
hard mailbox bound. The delayed caller uses the managed pull API; the separate
live security suite tests a blocked low-level streaming callback. Cache and
hardware descriptions are operator declarations. Read the recorded qualification
limitations before comparing trials or making latency/isolation claims.

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

The shared setup uses immutable profile `example-offline-v2`: 1 vCPU, 256 MiB
guest memory, 768 MiB VMM allowance, 20 GiB storage and 10 GiB overlay. Its
required worker allocation floor matches the supplied 1.14.1 disk templates.
These are accounting reservations, not hard host filesystem/RSS quotas. A host
with different or larger artifact templates must requalify and update the floor.
Existing v1 records retain their original spec: inspect their original handles;
reusing their ID with the changed profile intentionally returns an identity conflict.
