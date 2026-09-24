# Durable host example

SmolBox 0.2.0 defaults to smolvm **1.17.0**; 0.1.5 retains 1.16.1.
Follow [the coordinated upgrade guide](../../docs/upgrading-to-0.2.0.md) before
using new features against an existing store.
Set `SMOLBOX_RUNTIME_VERSION=1.16.1` explicitly for an existing 1.16.1 worker.
See [qualification](../../docs/compatibility.md#smolvm-1-17-0-qualification).

This standalone host owns an Ecto Repo and a PostgreSQL implementation of
`SmolBox.Store`. It includes a managed Python execution demonstration and a
real-worker process-kill recovery suite. A separate checkpoint demo restores
approved idle guest state while using the same PostgreSQL adapter and lifecycle.
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
On Linux x86_64 or macOS Apple Silicon,
omitting `SMOLBOX_RUNTIME_VERSION` selects 1.17.0 in this checkout
(0.1.3 defaults to 1.16.0). Set it to `1.16.1`, `1.16.0`, `1.14.6` or `1.14.1`
for an existing older worker. Consult the
[qualification evidence](../../docs/compatibility.md#smolvm-1-17-0-qualification). Supply the 1.14.6, 1.16.0, 1.16.1 or 1.17.0 host's `resize2fs` for smaller disk
requests; see [host prerequisites](../../docs/compatibility.md#macos-1-14-6-prerequisites).
Child controllers inherit the selection and require an
exact match with the server. Changing it does not upgrade the worker itself.
The examples use a 60-second client operation budget and a 55-second receive
budget for cold preparation. The profile separately bounds each execution stage;
these settings do not lengthen command execution or authorize a retry after a
lost response.
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
MIX_ENV=test elixir scripts/ci.exs worker-fault \
  --smolvm /absolute/path/to/smolvm \
  --url http://127.0.0.1:19471 \
  --python /absolute/path/to/python.smolmachine \
  --report /absolute/path/to/worker-restart-report.json
```

Run through the pinned toolchain so the child `mix` command uses it too. Supply
the same database configuration as above; Linux additionally requires an explicit
dedicated `SMOLVM_DATA_DIR`. The script refuses an occupied port, starts and kills
only its own server/controller processes, and requires an initially empty worker
inventory. It requires the explicitly selected runtime version, checks recorded creation evidence
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

## Checkpoint execution and recovery

This example requires SmolBox **0.1.5 or later**. Version 0.1.4 does not
include checkpoint execution. This demo uses only the guest shell and the fixture in
[`scripts/checkpoints/prepare-fixture.sh`](../../scripts/checkpoints/prepare-fixture.sh).
It requires smolvm **1.17.0** (or explicitly selected **1.16.1**), an approved idle offline checkpoint captured on the
same platform and compatible CPU, and the database configuration and migrations
described above. Read [checkpoint approval and upgrades](../../docs/checkpoints.md)
before registering the source. A digest verifies bytes, not whether captured
processes are safe to resume.

Run this example on the worker host. Prepare the fixture on a dedicated worker,
inspect its saved creation/start/exec replies, and remove the source VM only after
checking its creation identity. Preserve the checkpoint at an immutable approved
path. It contains `warm` in `/dev/shm/smolbox-marker`, `baseline` in
`/workspace/baseline`, and no pending user workload. The expected allocations are
1 vCPU, 256 MiB guest RAM, 1 GiB storage and 1 GiB overlay. The example reserves
another 256 MiB for host overhead; these are accounting values, not hard quotas.

Configure a new private object directory, distinct private 32-byte fingerprint
and encryption key files, and a dedicated store partition. Supply the digest
you verified during approval; the demo checks the local file against it:

```sh
export SMOLBOX_CHECKPOINT_SOCKET=/private/worker/api.sock
export SMOLBOX_CHECKPOINT_PATH=/approved/idle.smolcheckpoint
export SMOLBOX_CHECKPOINT_SHA256=replace_with_verified_sha256
export SMOLBOX_ARTIFACT_ROOT=/private/checkpoint-demo/objects
export SMOLBOX_FINGERPRINT_KEY_FILE=/private/checkpoint-demo/fingerprint.key
export SMOLBOX_ENCRYPTION_KEY_FILE=/private/checkpoint-demo/encryption.key
export SMOLBOX_STORE_PARTITION=checkpoint-demo
export SMOLBOX_EXECUTION_ID=restore-001
MIX_ENV=test mix run scripts/checkpoint_demo.exs
```

This submits `restore-001-first` and `restore-001-second`. Each restores the RAM
and disk markers, stages an input, writes a report of the original values, and
mutates its own copies of the markers. SmolBox then collects the outputs. Both
reports must still contain `warm`, `baseline` and `staged`.
Each collected counter must contain exactly one `x`, and cleanup must complete
before the demo finishes. The two records must have different machine names.

Run the **same command again in a new process**, retaining the partition, keys,
source approval and object directory. It retrieves the same execution records
and outputs; it does not submit new work under new identities. Use a new
`SMOLBOX_EXECUTION_ID` when you intentionally want another pair of executions.
Keep the directory and keys if an operation fails so you can inspect or recover
the records. Do not delete a partition to retry uncertain work.

The separate real recovery suite uses disposable PostgreSQL partitions and a
dedicated, otherwise idle worker. It needs only the three checkpoint environment
variables above plus the database settings; it creates its own object directories
and keys. Run fault testing in the disposable Linux lab:

```sh
MIX_ENV=test mix test test/checkpoint_recovery_runtime_test.exs \
  --include runtime --trace --warnings-as-errors
```

It launches fresh BEAM processes for completed-record recovery and independent
restores, then kills an owned controller immediately before or after the durable
result write. Before the write, recovery must preserve an unknown outcome without
replaying the command. After the write, it must recover the known result and
collect outputs. Both cases preserve source and machine identity, wait through
any real retention interval, verify VM absence and release capacity. The dispatch
ledger counts client attempts, not upstream acceptance receipts. This is a focused
checkpoint recovery check, not every failure boundary in the image suite above.
Unfinished cases retain private evidence for operator inspection; the test never
forces deletion after an uncertain stop.

## Opt-in durable benchmark

The benchmark uses this host's real PostgreSQL store, directory adapter and a
previously provisioned, initially idle smolvm worker matching `SMOLBOX_RUNTIME_VERSION`
(default 1.17.0). It provisions no
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

SmolBox 0.1.3 writes record schema v2, including offline executions, and reads
legacy v1 records as offline. All controllers sharing this database must upgrade
together; old readers cannot read v2, and there is no built-in downgrade after
v2 writes. Follow [Upgrading to 0.1.3](../../docs/recovery.md#upgrading-to-0-1-3).
This payload change does not add a SQL migration or change the encryption envelope.

SmolBox 0.1.5 additionally writes **record schema v3 for
checkpoint executions only**. Image executions retain v2 and existing image
fingerprints; v1/v2 reads remain supported. Upgrade **every controller sharing
the store before submitting checkpoint work**. An older controller cannot read
v3 and must not treat an unreadable record as absent. Downgrading once v3 records
exist requires an explicit separation or migration plan. See
[checkpoint persistence and upgrades](../../docs/checkpoints.md#persistence-and-upgrades).
This is another payload version, not a SQL table migration or a change to
`Store.capabilities/1`'s adapter contract schema.

The existing second SQL migration adds
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

## Persistent machines (0.2.0)

Apply the third migration, `20260922000000_managed_persistent_machines`, with all
controllers sharing these workers stopped and upgraded. It adds a separately
encrypted machine table and an execution association projection; prior disposable
payloads remain readable. All reservation transactions share the existing
partition lock. The down migration refuses to discard persistent identities.

The runtime now advertises `managed_machines: 1`. Machine payloads are bound to a
separate authenticated encryption domain, and indexed projections are checked
against decoded records. Existing machine-assignment backfill still applies only
to disposable assignments. Both assignment kinds remain available to inventory
audit after deletion. Run `test/machine_store_test.exs` for the additional shared
concurrency contract and encryption isolation check.

For the two-process walkthrough, configure the database plus the same environment
used by the image demonstration (`SMOLBOX_RUNTIME_URL`, optional
`SMOLBOX_RUNTIME_SOCKET`, `SMOLBOX_PYTHON_ARTIFACT`, `SMOLBOX_PYTHON_SHA256`,
`SMOLBOX_ARTIFACT_ROOT`, `SMOLBOX_FINGERPRINT_KEY_FILE`,
`SMOLBOX_ENCRYPTION_KEY_FILE`, `SMOLBOX_STORE_PARTITION`, and
`SMOLBOX_EXECUTION_ID`). The artifact directory must already exist with mode 0700;
both key files must contain 32 bytes. Use a dedicated approved 1.17.0 worker and an
image qualified for 2 GiB storage/overlay requests with working `resize2fs`.

```sh
MIX_ENV=test mix run scripts/persistent_machine.exs prepare
MIX_ENV=test mix run scripts/persistent_machine.exs resume
```

Keep all environment settings unchanged between these independent BEAM processes.
The first retains the machine and guest file. The second verifies file persistence
across reconnection and stop/start, then explicitly deletes and checks released
capacity. Failures leave durable evidence; do not erase records to start over.
See [the feature guide](../../docs/persistent-machines.md) for resolution and rollback.

The persistent-machine walkthrough refreshes an inspected version and retries
only `stale_version` / `not_dispatched` lifecycle conflicts, for up to five
seconds. It does not retry uncertain worker mutations. Each refresh is a new
lifecycle request; the walkthrough assumes one operator controls that handle.

## Persistent HTTP service

With the same durable configuration and a dedicated smolvm 1.17.0 worker, run:

```sh
mix ecto.migrate
export SMOLBOX_HTTP_PORT=18080
MIX_ENV=test mix run scripts/persistent_http.exs prepare
MIX_ENV=test mix run scripts/persistent_http.exs resume
```

Keep the partition, execution ID, fingerprint key and encryption key unchanged
between processes. Use fresh identities for another demonstration. The first
process creates a fixed TCP mapping, writes a file, starts a guest HTTP server and
verifies readiness and HTTP access. The second recovers the same machine, reaches
the existing service, stops/starts it, restarts the service and reads the same file
before verified deletion and release of all reservations. The worker's loopback
port must be reachable from the example process; `SMOLBOX_HTTP_URL` may point to
an operator-provided forwarding path ending in `/retained.txt`.

Port forwarding does not provide service supervision, TLS or authentication.
The guest process is restarted explicitly after VM stop/start. See the complete
[port mapping guide](../../docs/port-mappings.md), including outbound semantics,
worker binding, conflicts and recovery. Migrate and upgrade every controller
before managed writes: codec v5 applies even without ports, and rollback is not
safe merely because no new mapped machines are being created.

### Extended execution

The persistent HTTP example now uses `Command.new(..., background: true)` and
requires the upgraded adapter's `extended_execution: 1` capability. `prepare`
stores a typed PID result under `:launched`, then checks readiness with another
command. `resume` loads the original launch without replay, reaches the existing
service, and explicitly creates a new launch after stop/start.

Background and extended-budget records use codec v6; ordinary foreground records
retain their prior shapes. Upgrade every shared controller/reader/adapter together.
No new SQL migration is required beyond the existing migrations. Older binaries
cannot read v6 history; disabling new launches does not make rollback safe.
See [the guide](../../docs/long-running-exec.md) for semantics and recovery.

For a foreground example that actually runs beyond five minutes, use the same
environment, a fresh ID/partition, and a dedicated worker with at least ten minutes
of remaining lifetime:

```sh
MIX_ENV=test mix run scripts/long_foreground.exs
```

It approves a six-minute execution profile, requests a 330-second guest timeout,
runs a quiet 305-second Python command, checks output/exit status and verifies
normal disposable cleanup and reservation release. Its fixture uses 2 GiB
storage/overlay requests with qualified `resize2fs`; adjust the approved profile
and floors for other artifacts. A controller interruption preserves durable
uncertainty; rerunning an unknown identity does not replay its command.

## Interactive terminal example

After the database, worker, artifact and key setup above, select a fresh execution
ID and store partition and run `MIX_ENV=test mix run scripts/terminal.exs run`.
This demonstrates streamed terminal input/output, resize, exit, file retention and
explicit deletion. `shell` provides a line console: `:resize COLS ROWS`,
`:interrupt`, `:eof` and `:close`. It leaves the machine retained; `delete` removes
an idle machine. Host terminal settings are not changed.

For recovery, `interrupt` deliberately halts the controller with work active.
Fence the old controller and drain its worker requests before asserting
`SMOLBOX_TERMINAL_QUIESCED=true` and running `recover` with the same identity and
keys. If restarting the dedicated worker is part of that drain, run
`stop-for-drain` first: it verifies ownership and records a stop to preserve disks,
without resolving the execution. Then drain/restart and run `recover`. Upstream
1.17.0 removes formerly running machines whose processes died on API startup.
See [Interactive terminals](../../docs/interactive-terminals.md) for the full contract.

## Startup workloads and console diagnostics

With the environment above and smolvm 1.17.0, run
`mix run scripts/workload.exs prepare`, then `mix run scripts/workload.exs resume`
in a separate controller process with the same partition, ID and keys. The example
verifies startup arguments, environment, working directory, console snapshot/follow,
recovery, retained files, stop/start and explicit deletion with released capacity.
Automatic restart policies and app stdout/stderr capture are unsupported.
See the [workload guide](../../docs/workloads.md) for v8 upgrade/rollback requirements.
There is no new SQL migration; apply all existing migrations.

## Guest paths and 16 MiB files

After the normal PostgreSQL setup, use a private smolvm 1.17.0 image worker started
with `SMOLVM_FILE_TRANSFER_MAX_BYTES=16777216`. Set a fresh execution ID and store
partition, keeping the same artifact root and keys across both processes:

```sh
export SMOLBOX_EXECUTION_ID=guest-files-example-1
export SMOLBOX_STORE_PARTITION=guest-files-example-1
mix run scripts/guest_files.exs prepare
mix run scripts/guest_files.exs resume
```

The example stages a binary in `/app/project` and configuration under
`/home/dev/.config/smolbox`, executes in `/app/project`, collects/verifies 16 MiB,
then reconnects from a fresh controller, verifies files, stops/starts and reads
again. It explicitly deletes and verifies absence and released reservations.
`mix run scripts/guest_files.exs delete` is a separate authorized cleanup path.
The script uses immutable explicit path/byte approvals, 2/2 GiB artifact floors,
and codec v9; see [the guide](../../docs/guest-files.md) for prerequisites and
upgrade/rollback restrictions. File bodies are buffered, not streamed end to end.
