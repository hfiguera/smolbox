# Durable host example

SmolBox 0.3.1 defaults to smolvm **1.20.2**. Published SmolBox 0.3.0 and
0.2.1 retain their **1.19.0** default.
Follow [Upgrading to 0.3.0](../../docs/upgrading-to-0.3.0.md) before enabling
registry sources, exports, captures or branches against an existing store.
Applications coming from 0.1.x must also follow the
[0.2.0 migration guide](../../docs/upgrading-to-0.2.0.md).
Set `SMOLBOX_RUNTIME_VERSION=1.16.1` explicitly for an existing 1.16.1 worker.
See [qualification](../../docs/runtime-1.20.2-qualification.md).

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
mix quality
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix test --warnings-as-errors
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
omitting `SMOLBOX_RUNTIME_VERSION` selects 1.20.2 in this checkout
(0.1.3 defaults to 1.16.0). Set it to `1.16.1`, `1.16.0`, `1.14.6` or `1.14.1`
for an existing older worker. Consult the
[qualification evidence](../../docs/runtime-1.20.2-qualification.md). Supply the 1.14.6, 1.16.0, 1.16.1 or 1.17.0 host's `resize2fs` for smaller disk
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
(checkout default 1.20.2). It provisions no
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

## Shared store and browser example

The PostgreSQL adapter source now lives in `../support/store`; this project's
`elixirc_paths` compiles it without changing its `SmolBox.DurableHost` namespace or
store schema. Keep that directory when copying the example. Its migrations remain
in this project's `priv/repo/migrations`. The
[community workspace](../community_workspace/README.md) compiles the same adapter
and demonstrates the published 0.2.0 API through Phoenix LiveView.

## Example code-quality checks

Run `mix deps.get`, then `mix quality` from this example directory. The alias
selects `MIX_ENV=test` unless explicitly overridden and runs compilation with
warnings as errors, strict Credo with the ExSlop plugin, ExDNA with a zero-clone
budget, and Dialyzer with `--force-check`. CI runs the same alias. The tools are
development/test dependencies and are not included in production runtimes.

The local Credo configuration includes this app's source, tests, configuration,
scripts and compiled shared example code. ExDNA checks implementation and support
code with the repository's existing `min_mass: 30` threshold; repeated test-case
bodies are outside its scope. Dialyzer analyzes the app's compiled test-environment
modules against its own dependencies. Keep the local `.credo.exs` and `.ex_dna.exs`
when copying an example. A first Dialyzer run builds a PLT and can take several
minutes; subsequent local/CI runs reuse it while checking dependency changes.
These static checks do not start a worker and do not replace the example's tests
or real-worker qualification.
## Registry artifacts and machine images

`SmolBox.DurableHost.RegistryDemo` consumes an operator-approved source and keeps
its identity in PostgreSQL. It requires smolvm 1.19.0 or 1.20.2, a prepared environment with
`/bin/sh` and `/bin/cat`, and the database setup described below. Use isolated
worker data and store partitions for qualification. The declared 20 GiB storage,
10 GiB overlay and 768 MiB VMM overhead must cover your actual worker templates.
This example does not prepare or publish images.

Keep these values identical between invocations. Provision private, persistent
32-byte key files and a private artifact directory using your normal host setup.
The key bytes must not be placed in the environment or printed.

```sh
export SMOLBOX_WORKER_URL='http://127.0.0.1:19480'
export SMOLBOX_ALLOW_LOOPBACK=true
export SMOLBOX_PLATFORM=linux
export SMOLBOX_ARCHITECTURE=x86_64
export SMOLBOX_SOURCE_KIND=registry
export SMOLBOX_REGISTRY_REFERENCE='registry.example.com/team/environment@sha256:<platform-manifest-digest>'
export SMOLBOX_REGISTRY_CONTENT_SHA256='<prepared-file-sha256>'
export SMOLBOX_STORE_PARTITION=registry-demo
export SMOLBOX_EXECUTION_ID=computer-1
export SMOLBOX_ENCRYPTION_KEY_FILE=/private/keys/store.key
export SMOLBOX_FINGERPRINT_KEY_FILE=/private/keys/fingerprint.key
export SMOLBOX_ARTIFACT_DIR=/private/smolbox-objects

mix run -e 'SmolBox.DurableHost.RegistryDemo.run("prepare")'
# The first BEAM exits. Keep the worker and PostgreSQL running.
mix run -e 'SmolBox.DurableHost.RegistryDemo.run("resume")'
```

Use `macos` and `aarch64` on Apple Silicon. The loopback option is for a local
worker or protected tunnel; secure remote deployments require the worker's
protected endpoint. Configure the worker's registry credentials separately.

`prepare` creates and starts the machine, writes a file and reads it. `resume`
checks the recorded source, reads the file in a new controller process, stops and
starts the same machine, reads again, then explicitly deletes and verifies absence
and capacity release. Output includes source and preparation evidence, never keys.
Failures retain the original identity and machine for operator recovery.

To demonstrate OCI creation and a managed image pull, start a **new** example
identity with `SMOLBOX_SOURCE_KIND=oci`, set `SMOLBOX_REGISTRY_REFERENCE` to its
approved OCI platform manifest and `SMOLBOX_PULL_REFERENCE` to a different approved
OCI platform manifest. Set `SMOLBOX_REGISTRY_NETWORK_HOSTS` to the exact operator
allowlist needed by those registries, as comma-separated DNS names. Registry
authentication and content redirects may use additional hosts; SmolBox does not
add them automatically. Run `prepare`, then `images`, then `resume` in separate
BEAM invocations. The image step prints inventory counts and typed pull evidence;
the later reads verify that pulling did not replace the machine's files.

Managed image pulling is unavailable on prepared `.smolmachine` machines:
upstream returns synthetic `packed` metadata instead of fetching the requested
image. An empty inventory also cannot prove absence on a stopped VM.

## Export a stopped machine and reuse its artifact

`SmolBox.DurableHost.ExportDemo` runs three separate BEAM invocations against the
same PostgreSQL partition and keys. It writes `/app/export-proof.txt`, exports the
stopped machine, retrieves the durable result after restart, creates an explicitly
approved copy, verifies independent file contents, and deletes both machines.

Use an isolated, approved Alpine-compatible container artifact with `/bin/sh` and
`/bin/cat`. This example declares 2 GiB storage, 2 GiB overlay, and 768 MiB host
memory overhead; qualify those floors for your worker. Its export allowance is
four CPUs, 4608 MiB memory, and 128 GiB disk, additional to source reservations.
Ensure `SMOLVM_FILE_TRANSFER_MAX_BYTES` on the worker can accommodate the flattened
export layer; this host override also controls pack exports. A 1 MiB worker cap
used by security regression tests is unsuitable for this example.
Adjust the example configuration if the actual layers, templates, helper settings,
or staging needs exceed these declarations. Sparse disks still require enough
backing space. The example is not a quota enforcement mechanism.

First configure PostgreSQL as above, run `mix ecto.migrate`, and retain the same
32-byte encryption and fingerprint key files across all phases. Provision a
registry repository that rejects tag replacement. Its publisher token must be a
scoped OCI bearer with read and push permission, not the identity token used by
artifact warm. Keep the token in a private host file, outside version control.

```sh
export SMOLBOX_STORE_PARTITION=export-demo
export SMOLBOX_ENCRYPTION_KEY_FILE=/private/export-demo/encryption.key
export SMOLBOX_FINGERPRINT_KEY_FILE=/private/export-demo/fingerprint.key
export SMOLBOX_ARTIFACT_DIR=/private/export-demo/objects # existing mode 0700
export SMOLBOX_WORKER_URL=https://worker.example.com
export SMOLBOX_PLATFORM=linux
export SMOLBOX_ARCHITECTURE=x86_64
export SMOLBOX_EXPORT_BASE_PATH=/approved/alpine.smolmachine
export SMOLBOX_EXPORT_BASE_SHA256=<verified-prepared-artifact-sha256>
export SMOLBOX_EXPORT_ID=environment-one # a new immutable registry tag
export SMOLBOX_EXPORT_REGISTRY=registry.example.com
export SMOLBOX_EXPORT_REPOSITORY=team/environments
export SMOLBOX_EXPORT_TOKEN_FILE=/private/export-demo/publisher.token
mix run -e 'SmolBox.DurableHost.ExportDemo.run("prepare")'
```

For an isolated loopback test only, `SMOLBOX_ALLOW_LOOPBACK=true` enables HTTP
worker and registry endpoints. Worker authentication/TLS must be configured for
your real deployment; extend the example's endpoint options as appropriate.
The source and destination must already satisfy host approval requirements.

The first invocation prints the verified identity and leaves the source stopped,
with helper capacity still reserved. Inspect the worker host: fence pending export
requests, confirm all export helpers have exited, and verify this export's staging
cleanup. An HTTP 200 is not that evidence. Only after establishing quiescence:

```sh
SMOLBOX_EXPORT_QUIESCED=true mix run -e 'SmolBox.DurableHost.ExportDemo.run("confirm")'
```

Review the printed result and copy its complete digest reference as the explicit
approval for the final invocation. Optionally set
`SMOLBOX_EXPORT_READER_TOKEN_FILE` to a private identity-token file when the
existing registry pull contract requires it. This differs from the publisher
bearer; do not assume one token works for both. Public read access or worker-owned
pull authentication can omit the reader reference.

```sh
export SMOLBOX_APPROVED_EXPORT_REFERENCE=registry.example.com/team/environments@sha256:<verified-platform-manifest-sha256>
mix run -e 'SmolBox.DurableHost.ExportDemo.run("reuse")'
```

The final phase verifies that the copy initially contains `export-proof`, changes
it to `changed-copy`, reads `export-proof` from the original, and checks absence
and reservation release for both machines. It retains the export record and
registry artifact. Independently inspect the registry's manifest and artifact blob
after deletion; remove this test artifact only through an explicit registry
cleanup action. Do not blindly rerun a failed phase: inspect the durable machine,
command, and export records first, and resolve uncertain work before proceeding.

See [the export guide](../../docs/machine-exports.md) for preserved paths, cleanup
limitations, cancellation, immutable publication, and codec v11 upgrade/rollback.

## Managed checkpoint capture and restore

This checkout adds `ManagedCheckpointDemo`. It uses four separate application
processes with the same encrypted PostgreSQL store and keys. Run it on the worker
host: the example hashes the approved seed and capture paths locally, then explicitly
approves that same path for restore. Remote controllers must transfer the bytes and
verify their digest on the target worker separately.

Prepare and approve an **idle, offline bare** checkpoint captured with the selected worker runtime with 1 CPU,
256 MiB RAM and 1 GiB storage/overlay disks using the existing checkpoint fixture
procedure. No user processes, secrets, mounts or connections may be captured.
This seed is only the starting environment; the demo writes fresh disk and RAM
markers and captures a new managed checkpoint. Containers are not supported here.

With the database configured and migrated as above, create private directories and
stable 32-byte key files once, then retain them for every phase:

```sh
export SMOLBOX_STORE_PARTITION=checkpoint-demo
export SMOLBOX_CHECKPOINT_ID=prepared-state-1
export SMOLBOX_ENCRYPTION_KEY_FILE=/private/demo/encryption.key
export SMOLBOX_FINGERPRINT_KEY_FILE=/private/demo/fingerprint.key
export SMOLBOX_ARTIFACT_DIR=/private/demo/objects
export SMOLBOX_CAPTURE_ROOT=/private/demo/captures
export SMOLBOX_CHECKPOINT_SEED_PATH=/approved/idle.smolcheckpoint
export SMOLBOX_CHECKPOINT_SEED_SHA256=ACTUAL_VERIFIED_SHA256
export SMOLBOX_WORKER_URL=http://127.0.0.1:19680
export SMOLBOX_ALLOW_LOOPBACK=true
export SMOLBOX_PLATFORM=linux
export SMOLBOX_ARCHITECTURE=x86_64

mix run -e 'SmolBox.DurableHost.ManagedCheckpointDemo.run("capture")'
```

The capture root must already exist with mode 0700. The example reserves 16 GiB
of additional capture headroom and streams at most 1 GiB. These illustrative
values require host qualification; they are not enforced worker quotas. It sets
both HTTP operation and receive timeouts to 15 minutes.

After the capture process exits, fence pending requests and verify worker capture
and temporary staging are finished. A successful response alone is insufficient:

```sh
SMOLBOX_CAPTURE_QUIESCED=true \
  mix run -e 'SmolBox.DurableHost.ManagedCheckpointDemo.run("confirm")'
```

Review the captured state and copy the exact digest printed by the capture phase:

```sh
SMOLBOX_APPROVED_CHECKPOINT_SHA256=ACTUAL_CAPTURE_SHA256 \
  mix run -e 'SmolBox.DurableHost.ManagedCheckpointDemo.run("restore")'
```

This restores two independent machines, reads both `/workspace/disk` and
`/dev/shm/ram`, modifies the first copy, verifies the second and original remain
unchanged, and deletes all three managed machines. The checkpoint stays on disk
and its storage reservation remains. These commands are phase demonstrations, not
a recovery script: on interruption inspect records and follow the recovery guide
instead of replaying a whole phase.

Finally, after verifying there are no other retained copies, explicitly remove
this capture and release only its reservation:

```sh
SMOLBOX_REMOVE_CAPTURE=true \
  mix run -e 'SmolBox.DurableHost.ManagedCheckpointDemo.run("release")'
```

Release verifies the file digest before deleting it and retains durable identity
history. The seed, directories and keys remain host-owned. See the
[managed checkpoint guide](../../docs/managed-checkpoints.md) for unknown outcomes,
quiescence assertions, storage requirements and codec v12 upgrade/rollback rules.

## Managed branches

`ManagedBranchDemo` uses the same approved idle bare seed, environment, private
paths and stable keys as the checkpoint demo above. Select a fresh
`SMOLBOX_CHECKPOINT_ID` and retain the same PostgreSQL partition across phases.
It approves 8 GiB of extra backing capacity per child, separately from child
allocation. These are example budgets, not filesystem quotas.

```sh
mix run -e 'SmolBox.DurableHost.ManagedBranchDemo.run("prepare")'
mix run -e 'SmolBox.DurableHost.ManagedBranchDemo.run("verify")'
```

The first process prepares disk and RAM markers and creates two children. The
second reconnects through PostgreSQL, verifies both copies, changes one, verifies
source and sibling isolation, and tests child stop/start disk preservation. It
then deletes both children and verifies that backing capacity remains reserved.

After establishing that all previous requests are quiescent:

```sh
SMOLBOX_BRANCH_QUIESCED=true \
  mix run -e 'SmolBox.DurableHost.ManagedBranchDemo.run("retire")'
```

This retires deleted child dependencies and deletes the source. Backing allowance
still remains. Inspect the owned worker's source generations, child disks and
staging paths and confirm their removal before asserting cleanup:

```sh
SMOLBOX_BRANCH_BACKING_REMOVED=true \
  mix run -e 'SmolBox.DurableHost.ManagedBranchDemo.run("release-storage")'
```

The final phase verifies source/child absence and zero reservations while retaining
history. Never set either assertion just to get past a blocked operation.

For a separate held-release demonstration, use a fresh `SMOLBOX_CHECKPOINT_ID`:

```sh
mix run -e 'SmolBox.DurableHost.ManagedBranchDemo.run("held")'
```

This prepares the upstream `smolvm-branch-ready` guest boundary, creates one held
child, verifies lifecycle exclusion, explicitly releases it, retries the original
release version to check deduplication, reads disk/RAM state, and deletes the child.
Run the same `retire` and `release-storage` phases with that identity afterward,
only after the same quiescence and host cleanup checks. Do not replay whole phases
after interruption; inspect durable records and follow [branch recovery](../../docs/managed-branches.md).

## Durable worker admission controls

Apply `20260929000000_worker_admission_controls` with every writer stopped, then
upgrade all controllers before relying on durable draining. The adapter now
advertises `worker_control: 1` and checks admission in the same partition transaction
as drain/resume changes. Missing schema fails startup capability checks.

Control rows are separate from worker leases and encrypted machine/execution
payloads; there is no codec revision. The down migration refuses to discard control
history. Old writers can bypass these gates, so mixed versions and rollback during
maintenance are unsupported. See [worker draining](../../docs/worker-draining.md)
for the API, bounded maintenance pages, validation and safe rollout boundaries.

### Disk expansion

See [disk expansion](../../docs/disk-expansion.md) for the two-process
`SmolBox.DurableHost.DiskExpansionDemo` walkthrough. It grows a stopped ordinary
machine from 2/2 to 4/3 GiB, preserves a guest file across controller restart,
verifies both guest filesystems and explicitly deletes the machine. Use a fresh
execution ID and partition and preserve the same keys between phases.

Expansion requires codec v14 support in all readers and resource projection
writers sharing the store. No additional SQL migration is introduced beyond the
existing worker-control table. Old readers cannot decode expansion history,
including deleted tombstones; do not roll back to incompatible code.

### Local volumes

Apply migration `20260930000000_local_volumes` with writers stopped. Upgrade all
controllers and adapters to codec v15 and atomic `local_volumes: 1` support before
enabling mounts. Down migration refuses to discard volume identities, including
tombstones; rollback to old readers/writers with volume history is unsupported.

With the environment from the setup section, an approved Python image, Linux
smolvm 1.20.2 and a fresh execution ID/partition:

```sh
# Match the worker's actual canonical local volume directory.
export SMOLBOX_VOLUME_ROOT=/srv/smolvm/.local/share/smolvm/volumes
mix ecto.migrate
mix run -e 'SmolBox.DurableHost.VolumeDemo.run("prepare")'
mix run -e 'SmolBox.DurableHost.VolumeDemo.run("resume")'
```

Keep the same keys, ID, worker and partition between processes. `prepare` writes a
file on a volume, verifies attached deletion is blocked and deletes the original
machine. `resume` mounts it in a replacement, reads/modifies the file, verifies a
read-only attachment and explicitly deletes the machines and volume. The final
reservation is zero. Inspect records after interruption rather than replaying a
whole phase blindly.

The demo uses 2 GiB machine storage, 2 GiB overlay and a 2 GiB advisory volume
reservation within a 10 GiB worker budget. Verify your fixture supports these
allocations and your host permission policy supports replacement writes. This is
not a filesystem quota or a multi-tenant isolation test. See [local volumes](../../docs/local-volumes.md)
for permission requirements, recovery and the native Linux evidence.
