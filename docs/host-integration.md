# Managed host integration

SmolBox **0.2.1** defaults to **smolvm 1.19.0** on Linux x86_64 and macOS Apple
Silicon. Version 0.2.0 defaults to 1.17.0. Keep existing workers explicitly pinned
to their installed version; updating SmolBox does not install smolvm. See
[Upgrading to 0.2.1](upgrading-to-0.2.1.md) and the
[1.19.0 qualification](runtime-1.19.0-qualification.md).


Start with [Getting started](getting-started.md) for a complete runnable example.
This guide explains how to adapt that flow to your application's supervision,
authorization, durable storage, and worker configuration. Constructor options are
documented in `SmolBox.child_spec/1` and `SmolBox.Runtime.WorkerConfig.new/1`.

See [telemetry and inspection](telemetry.md) for bounded lifecycle observations,
notification failure semantics, and authoritative operator fields.
See [deployment boundaries](security.md) for worker/proxy setup, artifact trust,
storage responsibilities and upgrade/recovery procedures.

The managed runtime has real Linux/macOS execution and durable fault recovery
coverage. A subsequent
[Linux deployment campaign](resource-qualification.md#subsequent-linux-deployment-validation)
also verified external worker resource limits and failure recovery in one
constrained nested configuration. The library's supported qualification remains
`:development`; the host configuration below does not install those external
controls. Multi-tenant operation and macOS host enforcement are outside that
campaign's scope.

The host owns authorization, prepared runtime artifacts, worker installation,
proxy credentials, durable storage operation, and artifact retention. SmolBox
manages identity, admission, ownership evidence, observation, and recovery for
both disposable executions and retained machines. `SmolBox.submit/2` runs one
command per disposable VM and tracks its cleanup. `SmolBox.Machines` gives a
retained VM its own lifecycle and reservations, independent of successive commands;
command completion or cancellation does not delete it. The host authorizes its
explicit deletion and any recovery action. See
[Retained machine integration](#retained-machine-integration-0-2-0).
SmolBox does not interpret JSON business results or build/publish language packages.

## Explicit supervision

Start a conforming store and artifact adapter first. `SmolBox.Store.Memory` is
available only with explicit `mode: :ephemeral`. Default durable mode rejects it.
The repository's Ecto/Postgres example owns its Repo and migrations separately.
A custom store must implement the full behaviour and pass conformance tests;
capability declarations alone do not certify its implementation.

For retained machines, implement all operations documented in
`c:SmolBox.Store.machine/3` before advertising `managed_machines: 1`. Its callback
signatures distinguish machine records, execution records and paginated results;
the operation table specifies each positional argument list. The callback remains
`machine(context, operation, arguments)` and requires no adapter or schema migration.
In particular, `:finish` takes an execution key and guard, while `:resolve` takes a
machine key and guard. Both must update the machine and its command atomically.

Configure worker endpoints with `SmolBox.Worker.new/3`, then construct a client
with `SmolBox.Client.new/2`. Remote workers require verified HTTPS and a bearer
token. Proxy tokens stay in trusted configuration, outside persisted records.

```elixir
{:ok, profile} = SmolBox.Profile.new("offline-policy-v2",
  storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768)
{:ok, configured_worker} = SmolBox.Runtime.WorkerConfig.new(
  client: client,
  platform: :linux,
  architecture: "x86_64",
  runtime_version: "1.14.6",
  profiles: [profile],
  artifacts: [%{
    "id" => "python-v1",
    "sha256" => approved_artifact_sha256,
    "architecture" => "x86_64",
    "path" => "/approved/python-v1.smolmachine"
  }],
  allocation_floor: %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768},
  capacity: %{slots: 2, cpus: 2, memory_mb: 2048, disk_gb: 60}
)

children = [
  {SmolBox,
    name: MyApp.Sandboxes,
    namespace: "myapp",
    store: {MyApp.SmolBoxStore, store_context},
    artifact_store: {MyApp.ArtifactStore, artifact_context},
    fingerprint_key: stable_secret_key,
    workers: [configured_worker],
    max_pending: 128,
    max_active: 4}
]
```

This fragment explicitly retains a Linux 1.14.6 worker with SmolBox 0.2.0.
Omitting the field selects 1.19.0 in 0.2.1, 1.17.0 in 0.2.0 (1.16.1 in 0.1.5). Use `"1.16.0"`
explicitly to retain that worker, or `"1.14.1"`
for an existing worker. See [runtime selection](compatibility.md#runtime-selection).
This is a host configuration fragment, not a self-provisioning script. The host
must verify artifact bytes on the worker and retain that immutable artifact.
This disposable execution setup requires neutral `/bin/true` startup and no
automatic workload restart. Retained image machines can instead use explicitly
approved [startup workloads](workloads.md) on smolvm 1.17.0 or 1.19.0.
Neither HTTP reachability nor a supplied digest proves those facts. `platform`
is `:linux` or `:macos`; architectures initially tested are Linux `x86_64` and
macOS `aarch64`. Linux arm64 remains unqualified.

`allocation_floor` is required and has no inferred default. Verify the largest
storage/overlay templates across the runtime installation and every approved
artifact, plus VMM overhead, before registering a worker. The 1.14.1 release's
supplied templates measured 20 GiB storage and 10 GiB overlay on both hosts.
smolvm 1.14.1 retains a larger template even when its API reports a 1 GiB request.
Managed submission rejects profiles below the declared floor. Recovered work
checks the current floor again before dispatch; raising it does not rewrite an
existing specification or silently repeat a command. The low-level client cannot
detect this mismatch from the API response alone.

The example reserves 256 MiB guest memory plus 768 MiB VMM overhead per slot.
Linux source and a delegated cgroup observation support this VMM allowance for
the tested non-CUDA configuration. It is not a universal RSS bound, and macOS
does not provide the same cgroup controls. Disk reservations exclude shared
artifact caches, logs, layers, filesystem metadata and unrelated workloads.
Operators must separately bound and account for those resources. A floor is a
trusted configuration declaration, not an attestation or hostile-tenant quota.

Each physical worker must have one stable ID and one shared store authority.
Exact duplicate endpoint configurations are rejected, but aliases/proxies can
hide physical identity; the operator must prevent that configuration error.
Worker leases fence store writes, not requests already sent to the worker.
Changing the store partition or namespace is not safe controller takeover.

The supervision tree contains a task supervisor and a coordinator. The
coordinator launches bounded asynchronous scans and observers; it does not wait
on guest commands. Empty worker configuration starts without network I/O and
still permits inspection of persisted identities. Restarted observers use stored
state and never replay a possibly dispatched command.

## Files and submission

Use `SmolBox.ArtifactStore` for approved input reads and immutable output writes.
`SmolBox.ArtifactStore.Directory` provides a small local adapter for a private
host-owned directory with mode 0700. It bounds reads, verifies digests, and uses
atomic hard-link installation to refuse conflicting output snapshots. The host
owns disk quotas, directory durability, and artifact/temporary-file retention.
Guests must have no access to that directory or its ancestors.

```elixir
{:ok, command} = SmolBox.Command.new(["python", "/workspace/main.py"])
{:ok, spec} = SmolBox.ExecutionSpec.new(
  scope: "authorized-tenant",
  id: "request-123-attempt-1",
  artifact: %{
    "id" => "python-v1",
    "sha256" => approved_artifact_sha256,
    "architecture" => "x86_64"
  },
  command: command,
  profile: profile,
  inputs: [%{
    "source" => "approved-source-123",
    "path" => "/workspace/main.py",
    "size" => source_size,
    "sha256" => source_sha256,
    "mode" => "runtime_default"
  }],
  outputs: [%{
    "destination" => "result-123",
    "path" => "/workspace/result.bin",
    "max_bytes" => 65536
  }]
)

{:ok, handle} = SmolBox.submit(MyApp.Sandboxes, spec)
{:ok, snapshot} = SmolBox.await(MyApp.Sandboxes, handle, 30000)
```

Acceptance persists the spec and HMAC fingerprint. Keep the fingerprint key
stable across restarts and distinct from a database encryption key. Matching
scoped duplicates return the original handle even if that worker/profile is
later removed from configuration. Conflicting specifications fail.

For the disposable execution above, preparation reserves CPU, guest memory plus
declared host overhead, disk allocations, and a slot before VM creation. It
persists an opaque machine name, creates the prepared VM, records creation
evidence, starts its neutral workload, and stages inputs. Both the input read and
a download after staging must match
the declared size and SHA-256 before dispatch intent is written. An ambiguous
creation without persisted creation evidence never authorizes adoption or deletion
using the name alone. A missing-machine observation is also insufficient when
creation may still be in flight: that reservation remains held, even if the
worker currently returns 404. Operator recovery must first establish that the
old worker request cannot subsequently create the resource.

The default command channel is SSE with bounded lossy UTF-8 output. Commands with
supported text stdin use the byte-preserving buffered endpoint because the pinned
SSE endpoint ignores stdin. These paths still need full upstream resource-abuse
qualification. Known output overflow can retain an exit code with an empty,
`truncated: true` result; overflow before an exit leaves an unknown outcome.
`byte_size(result.stdout)` and `byte_size(result.stderr)` are captured byte counts,
not estimates of bytes discarded by the worker.

After an observed exit, SmolBox checks that the owned VM is still running before
reading each declared output. Download can start a stopped VM upstream, so
collection assumes exclusive control of this namespace; it never runs after
SmolBox confirms termination. Files are individual bounded byte snapshots, not
an atomic multi-file filesystem snapshot. Output storage is keyed by execution
identity and destination: identical retries succeed, changed content conflicts.
A collection failure preserves the command exit and any already recorded outputs.

## Read-only orphan inspection

`SmolBox.audit_worker(runtime, worker_id, limit: 20)` compares a bounded page of
namespace candidates with stored assignments. Pass the returned `next_cursor`
to continue; restart at nil for a fresh scan. This operator API spans scopes, so
the host must authorize it independently of an end user's execution handle.

| Status | Meaning |
|---|---|
| `owned` | Recorded assignment and creation fields match the current observation; exclusive namespace control and weak upstream identity still apply |
| `untracked` | The authoritative store lookup found no assignment; the name does not prove ownership |
| `unverified` | Assignment exists but creation evidence was never persisted |
| `conflict` | Recorded creation fields differ; leave the resource untouched |
| `cleanup_conflict` | The worker list observed a machine while the record says cleanup complete; this can be concurrent deletion or possible reappearance |
| `unavailable` | Store lookup timed out, failed, or returned unusable evidence; this is not absence |

The API sends one list request and read-only store lookups. It does not adopt,
reserve, stop, delete, execute, or download files. Pages are separate observations,
not an atomic snapshot; investigate and rescan before deciding on manual action.
Foreign names are counted, not treated as owned candidates. A worker response
outside the supported machine and network policy contract fails decoding rather than weakening
that contract. A page has at most 100 candidates, a one-second list budget and
500 ms per lookup with four lookups at a time. No code, environment, secrets,
stdout/stderr, or artifact content appears in the report.

Store adapters must implement `find_machine/3` and preserve the worker/name index
atomically with reservation, including after cleanup. An incomplete or unavailable
index must fail closed. The durable example supplies a unique SQL index and an
explicit authenticated backfill for records from its earlier migration.

## Cancellation, deadlines, and cleanup

`SmolBox.cancel(runtime, scope, id)` persists intent. Before dispatch, the record
can become `cancelled` with `not_dispatched` evidence. After dispatch, a stopped
VM without a command receipt remains an unknown command outcome, with separate
`termination_confirmed` evidence. A known exit wins over an overlapping cancel
request. Fetch the record to inspect all dimensions; an acknowledgment is not
proof of termination.

`await` timing out only stops that caller's wait. Preparation, execution,
collection, and cleanup use persisted absolute deadlines plus monotonic elapsed
time within each observer. Wall-clock rollback cannot extend that observer's
budget. Hosts must synchronize clocks across controllers. Concurrent store
mutations keep `updated_at_ms` nondecreasing even if request timestamps arrive
out of order. Deadlines are not reset on restart.

For disposable executions, unknown work is stopped promptly when ownership permits
it. Guest disks remain until the persisted execution deadline plus `retention_ms`;
this is the evidence-retention policy, not a result-recovery promise. These
disposable VMs are checked periodically, including for a previously sent exec that
arrives after stop and implicitly starts the VM again. Stop is an observation of
termination at that point in time; it does not fence pending worker requests.
Reobserving a running VM revokes that current termination evidence until another
stop is confirmed. The original command remains unknown and is never resent. For these records,
the fixed cleanup deadline includes that intentional wait followed by the cleanup
budget. Machines held for this evidence retention or failed cleanup
continue to consume reservations.

Cleanup checks creation evidence before stop/delete and verifies absence before
releasing capacity. Disposable VMs are deleted directly after command completion
and collection; unknown executions retain their disks and use graceful stop until
retention expires.
A stop failure during retention never authorizes immediate disposal. See the
[recovery guide](recovery.md#preservation-and-disposal) for the state and budget
rules. Failed cleanup does not rewrite successful command results.
Retries are bounded. After exhaustion, automatic work only inspects periodically;
it sends no more mutations. `reconcile` can request earlier inspection and can
confirm absence after an operator has resolved a resource whose creation was
already verified. Missing creation evidence requires separate operator resolution;
a momentary 404 cannot authorize releasing that reservation. It cannot bypass
ownership checks or authorize another command.

Retained machines have a different lifetime. Cancelling a managed command does
not automatically stop or delete its machine. An unknown command keeps the
machine's command slot occupied until explicit recovery; neither a caller timeout
nor an observed stop fences requests already sent to the worker. Machine retention
does not use execution `retention_ms`: stopped, missing and uncertain machines
keep their reservations. Release requires verified deletion or absence after
operator quiescence. Follow the
[managed-command recovery procedure](persistent-machines.md#cancellation-and-uncertain-outcomes)
before permitting reuse. Execution history and deleted machine identities remain
in the store for deduplication.

`drain_worker` excludes a worker from subsequent admission-task launches in this
runtime while preserving observation and cleanup. An admission task already in
flight may finish assigning work; draining is not an atomic worker-side fence or
cancellation request. Persist intended drain configuration in the host and use
`draining: true` when restarting; the convenience call itself is runtime-local.

Worker reports include the host-approved version/qualification, the latest typed
health observation and its wall-clock timestamp. Health age uses monotonic time.
The controller refreshes probes about every five seconds in groups of at most
four workers; stale observations are unavailable. Each HTTP probe has a 500 ms
operation deadline, and health JSON is capped at four KiB. A slower healthy host
can therefore be withheld conservatively. Long probes never run in the coordinator.

| Status | Admission meaning |
| --- | --- |
| `ready` | The reported version matches the worker's explicitly configured supported version, inventory is available, and readiness succeeded |
| `degraded` | The server responded, but inventory or blocking-pool readiness was unavailable |
| `incompatible` | The server reported a different runtime version |
| `unavailable` | No current valid probe or worker ownership claim is available |
| `draining` | Host configuration or this runtime's drain flag excludes new task launches |

Admission tries matching workers in configured order, with fresh health/readiness
checks before reservation. It rechecks cancellation and the original queue deadline
after probing. Prepared work is checked again before dispatch intent, so version
drift does not silently run a command against another runtime release. A failed
preparation still uses recorded identity for cleanup. Inspection and cleanup remain
available when a worker is incompatible or draining; health never authorizes
deleting an untracked resource.

The store atomically charges slots, configured CPUs, guest memory plus the
profile's host-memory overhead, and requested disk allocations. These are
accounting reservations, not measurements or hard
host limits. Operators must leave overhead and account for other host workloads.
Pending acceptance and active controller tasks are separately bounded. Capacity
exhaustion keeps accepted work queued until its fixed deadline; a full acceptance
queue returns `:admission_exhausted`. Identical existing identities still resolve.
The initial scheduler has no cross-tenant priority or strict fairness guarantee.

Runtime version and readiness cannot certify artifact availability or host quotas.
The host still verifies immutable artifact bytes, OS/architecture and the exact
profile revision. Unsupported profile controls and duplicate endpoint registrations
are rejected. Endpoint aliases cannot be discovered reliably by this client: each
physical worker must have one store authority. Active-active execution fencing is
not supported by upstream; deploying competing controllers does not create it.

Recovery rechecks the current artifact/profile approval before dispatching an
execution still in the prepared state. Removing that approval prevents command
dispatch and fails preparation; verified cleanup can still proceed through the
original worker. Existing handles remain inspectable. This does not cancel a
command whose dispatch may already have happened, and it does not rewrite an
observed result. Keep worker endpoints configured while they own unresolved work.

Stopping the runtime stops observers with bounded supervision shutdown. It does
not promise that a guest stopped. Restart with the same store and fingerprint key
to reconcile. Memory mode loses this authority when its store process stops.

## Upgrading a worker

SmolBox 0.2.1 defaults to smolvm **1.19.0**; 0.2.0 defaults to **1.17.0** on Linux x86_64 and macOS Apple
Silicon. SmolBox 0.1.4 and 0.1.5 default to **1.16.1**. SmolBox 0.1.3 defaults
to 1.16.0; 0.1.2 defaults to 1.14.6. Worker selection does not migrate execution records.
When upgrading controllers from 0.1.x, follow the coordinated
[0.2.0 controller and store upgrade](upgrading-to-0.2.0.md) separately.
Before enabling checkpoints in 0.1.5, follow the separate
[controller and schema-v3 upgrade procedure](recovery.md#upgrading-to-0-1-5).
Applications upgrading from 0.1.2 still need the
[0.1.3 record upgrade procedure](recovery.md#upgrading-to-0-1-3).
Before updating the library with an existing worker, retain its version explicitly:

```elixir
{:ok, worker} = SmolBox.Runtime.WorkerConfig.new(
  Keyword.put(existing_worker_options, :runtime_version, "1.17.0")
)
```

Use `"1.16.1"`, `"1.16.0"`, `"1.14.1"` or `"1.14.6"` instead for a worker still on either version. Omitting
`:runtime_version` expects `"1.19.0"` in 0.2.1 (`"1.17.0"` in 0.2.0) (`"1.16.1"` in 0.1.5); updating the Elixir
dependency does not install smolvm. A version mismatch prevents new execution.
Unverified versions and unsupported host combinations fail configuration
validation. Health checks require an exact version match, without fallback.

Review the [1.19.0 qualification and upgrade
boundaries](runtime-1.19.0-qualification.md) before upgrading.
The same drain, identity and prerequisite checks below apply to each supported
version. Configure the same expected version on every controller owning the worker.

For an existing worker:

1. Pause submissions at the application boundary and persist its drain setting.
   Drain all controllers sharing the authoritative configuration. The convenience
   drain call cannot retract an admission or request already in flight.
2. Keep the original endpoint and store available until owned executions have
   finished observation, collection and verified cleanup. Resolve unknown work
   using its original identity; do not resubmit commands or discard reservations.
   Retained machines do not expire when commands finish. This empty-worker
   procedure also requires their explicitly authorized deletion and verified
   absence. If they must be preserved, defer this procedure; SmolBox does not
   migrate retained machines to another worker.
3. Once the worker is empty and no requests remain in flight, stop it and install
   the complete pinned distribution. Verify binary, agent, libkrun and artifact
   digests. Do not mix files from different distributions.
4. Recheck the deployment controls and approved artifact/profile revisions.
   Disk requests below the 1.14.6, 1.16.0, 1.16.1, 1.17.0 or 1.19.0 templates require
   working `resize2fs` on the worker host (`brew install e2fsprogs` on macOS).
   Missing it caused file loss
   after restart in our macOS check, despite successful health/start/exec replies.
   Verify a small owned file survives stop/start before admitting work; see
   [the observed failure](compatibility.md#macos-1-14-6-prerequisites).
   API allocations still do not prove host storage quotas. Retain conservative
   floors until measured.
5. Update the expected version, start the worker, verify health/readiness and
   empty inventory, run an owned smoke execution through cleanup, then resume
   admission. Rollback also requires a drained worker; do not assume its modified
   registry or live VM state can be opened safely by the older runtime.

No persisted SmolBox record schema or fingerprint change is needed for the
version option. Changing an artifact or profile still changes execution meaning;
use a new approved revision and never rewrite an already accepted specification.

## Unfenced worker requests

The pinned worker takes a machine reference before exec's implicit-start lifecycle
lock. Stop and delete use lifecycle locks, but neither supplies durable command
identity nor a request-fencing token. Controller leases cannot retract requests
already accepted by a proxy or worker. A delayed original request can arrive after
a stop; this is possible without SmolBox issuing any retry.

Do not treat `termination_confirmed` as a guarantee that no queued request can
subsequently start work. For disposable executions, the runtime continues observation
during unknown-outcome retention and stops a reobserved owned VM. Hard deadline/cancellation guarantees
under arbitrary proxy queues, worker scheduler stalls, or controller loss require
an independently verified worker-side fencing/quiescence mechanism. None is
certified in this implementation. A configured execution deadline is an
observation budget plus an upstream command timeout, not proof of bounded wall
clock termination under those failures.

## Retained machine integration (0.2.0)

The same supervised runtime can serve `SmolBox.Machines` and disposable
`SmolBox.submit/2` work. Retained machines require the optional store capability
`managed_machines: 1`; existing adapters without it continue to support disposable
executions. The memory and PostgreSQL example adapters implement the extension.
Read [Managed persistent machines](persistent-machines.md) before enabling it on
shared workers, particularly the coordinated upgrade and capacity accounting.

Mapped machines additionally require `managed_ports: 1` and smolvm 1.17.0 or 1.19.0. Their
ports belong to the worker host, not necessarily this application's host. Use one
stable worker ID and authoritative store, including across controller restarts.
The PostgreSQL port-ownership index arbitrates fixed ports atomically; it does not
reserve operating-system sockets against unrelated processes. Read the
[port deployment and upgrade guide](port-mappings.md) before exposing services.

## Long commands and background launch

See [Long-running execution](long-running-exec.md) for coordinated codec-v6/store
upgrades, extended observation budgets and background launch recovery. A confirmed
launch is `:launched`, with a typed PID result; it does not prove readiness or
continued process life. Lost launch evidence stays unknown and must not be replayed.
Background processes can overlap later file operations. Stop/start requires an
explicit new service launch; cancellation does not perform PID-based termination.

## Interactive session integration

Approve finite terminal session and buffer limits through the selected profile,
then submit a `Terminal.Spec` using `Terminal.open/3`. Claim the connection with
`Terminal.attach/3` from the process that will consume it. The handle stays on that
controller and process; route input and resize requests through that owner. Use
pull-based `Terminal.next/2` to avoid accumulating streamed messages in a caller's
mailbox. Handle its closed event separately from confirmed exit evidence.

Live terminal buffers have bounded retention and may be retired when later sessions
need runtime capacity. Durable execution history does not contain a transcript.
See [Interactive terminals](interactive-terminals.md) and the durable host's
`terminal.exs` example for configuration, line-input console and restart recovery.

## Startup workloads and console diagnostics

Before allowing startup workloads, authorize their code and environment alongside
artifact, profile and scope. Require smolvm 1.17.0 or 1.19.0 and `managed_workloads: 1` on the
store; upgrade all shared readers first. Application readiness needs a separate
probe. Console followers consume bounded worker connections and do not own machine
lifetime. See [workloads](workloads.md) for configuration and operational limits.

## Guest path and file approval

Host-selected `GuestPaths` policies authorize uploads, downloads and ordinary
command working directories independently. Register the immutable profile on the
worker, approve a superset on its client, coordinate transport and artifact-store
limits, and set a worker download cap before startup. Expanded profiles require
image sources on smolvm 1.17.0 or 1.19.0 and store capability `guest_files: 1`. Defaults stay
unchanged. See [guest files](guest-files.md) for code and the v9 upgrade procedure.
