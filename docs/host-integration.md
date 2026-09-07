# Managed host integration

The managed runtime is implemented and has initial real Linux/macOS execution
coverage. Full fault and resource qualification is still in progress. Its current
worker qualification is explicitly development use; do not advertise it as a
production multi-tenant isolation certificate.

The host owns authorization, prepared runtime artifacts, worker installation,
proxy credentials, persistence, and artifact retention. SmolBox owns one command
per disposable machine, identity, observation, and evidence-based cleanup. It
does not interpret JSON business results or build/publish language packages.

## Explicit supervision

Start a conforming store and artifact adapter first. `SmolBox.Store.Memory` is
available only with explicit `mode: :ephemeral`. Default durable mode rejects it.
The repository's Ecto/Postgres example owns its Repo and migrations separately.
A custom store must implement the full behaviour and pass conformance tests;
capability declarations alone do not certify its implementation.

Configure worker endpoints with `SmolBox.Worker.new/3`, then construct a client
with `SmolBox.Client.new/2`. Remote workers require verified HTTPS and a bearer
token. Proxy tokens stay in trusted configuration, outside persisted records.

```elixir
{:ok, profile} = SmolBox.Profile.new("offline-policy-v1")
{:ok, configured_worker} = SmolBox.Runtime.WorkerConfig.new(
  client: client,
  platform: :linux,
  architecture: "x86_64",
  profiles: [profile],
  artifacts: [%{
    "id" => "python-v1",
    "sha256" => approved_artifact_sha256,
    "architecture" => "x86_64",
    "path" => "/approved/python-v1.smolmachine"
  }],
  capacity: %{slots: 2, cpus: 2, memory_mb: 1024, disk_gb: 4}
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

This is a host configuration fragment, not a self-provisioning script. The host
must verify artifact bytes on the worker and retain that immutable artifact.
Its image must have neutral `/bin/true` startup and no automatic workload restart.
Neither HTTP reachability nor a supplied digest proves those facts. `platform`
is `:linux` or `:macos`; architectures initially tested are Linux `x86_64` and
macOS `aarch64`. Linux arm64 remains unqualified.

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

Preparation reserves CPU, guest memory plus declared host overhead, disk
allocations, and a slot before VM creation. It persists an opaque machine name,
creates the prepared VM, records creation evidence, starts its neutral workload,
and stages inputs. Both the input read and a download after staging must match
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
outside the strict offline machine contract fails decoding rather than weakening
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

Unknown executions are stopped promptly when ownership permits it. Their guest
disks remain until the persisted execution deadline plus `retention_ms`; this is
the evidence-retention policy, not a result-recovery promise. Retained unknown
machines are checked periodically, including for a previously sent exec that
arrives after stop and implicitly starts the VM again. Stop is an observation of
termination at that point in time; it does not fence pending worker requests.
Reobserving a running VM revokes that current termination evidence until another
stop is confirmed. The original command remains unknown and is never resent. For these records,
the fixed cleanup deadline includes that intentional wait followed by the cleanup
budget. The original command is never resent. Retained or failed-cleanup machines
continue to consume reservations.

Cleanup checks creation evidence before stop/delete and verifies absence before
releasing capacity. Failed cleanup does not rewrite successful command results.
Retries are bounded. After exhaustion, automatic work only inspects periodically;
it sends no more mutations. `reconcile` can request earlier inspection and can
confirm absence after an operator has resolved a resource whose creation was
already verified. Missing creation evidence requires separate operator resolution;
a momentary 404 cannot authorize releasing that reservation. It cannot bypass
ownership checks or authorize another command.

`drain_worker` prevents new admission in this runtime while preserving existing
observation and cleanup. Persist intended drain configuration in the host and use
`draining: true` when restarting; the convenience call itself is runtime-local.
Worker reports distinguish reachability and drain state, and carry the explicit
qualification label. A reachable worker is not proof of artifact availability or
host quotas. A failed preparation is reported without enabling guest networking.

Stopping the runtime stops observers with bounded supervision shutdown. It does
not promise that a guest stopped. Restart with the same store and fingerprint key
to reconcile. Memory mode loses this authority when its store process stops.

## Unfenced worker requests

The pinned worker takes a machine reference before exec's implicit-start lifecycle
lock. Stop and delete use lifecycle locks, but neither supplies durable command
identity nor a request-fencing token. Controller leases cannot retract requests
already accepted by a proxy or worker. A delayed original request can arrive after
a stop; this is possible without SmolBox issuing any retry.

Do not treat `termination_confirmed` as a guarantee that no queued request can
subsequently start work. The runtime continues observation during unknown-outcome
retention and stops a reobserved owned VM. Hard deadline/cancellation guarantees
under arbitrary proxy queues, worker scheduler stalls, or controller loss require
an independently verified worker-side fencing/quiescence mechanism. None is
certified in this implementation. A configured execution deadline is an
observation budget plus an upstream command timeout, not proof of bounded wall
clock termination under those failures.
