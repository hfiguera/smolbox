# Capture and restore a managed checkpoint

Prepare useful state once, capture it, and restore independent managed machines.
Unlike an export, a checkpoint includes memory and resumes captured processes.
The first managed capture contract is deliberately **idle, offline, bare guests on
smolvm 1.19.0 or 1.20.2**. See [managed branches](managed-branches.md) for live copies.
Capture does not add arbitrary application resume,
network restoration, in-place rollback, migration or automatic backups.

## What is supported

A source opts into `checkpointable: true` in its immutable
`SmolBox.ManagedMachineSpec`. It must have offline networking, no port mappings,
no startup workload and a local artifact or approved checkpoint source. Its local
artifact must boot a bare guest. Container guests are rejected at start/capture
preflight: their checkpoints can depend on separately retained image packs, whose
lifecycle this feature does not manage. Ordinary machine creation and existing
checkpoint executions keep their previous behavior when the option is omitted.

Capture also checks the bounded portable manifest before publishing a result. Its
runtime, platform and allocations must match the source. Captures containing
external packed image dependencies, container workload metadata, credential
metadata or network configuration are not reusable through this API. Some bare
VM artifacts still retain a dependency on their original image pack; this is
only visible in the completed capture. Rejection at that point leaves the capture
unknown, preserves the file and reservations, and requires explicit recovery.
Manifest inspection does not prove that guest RAM is idle or free of secrets,
nor replace upstream payload integrity and CPU compatibility checks at restore.


Starting an opted-in machine uses `POST /api/v1/machines/:name/start?branchable=true`.
Capture uses `POST /api/v1/machines/:name/checkpoint` with no cache key or upload URL.
Upstream requires a running checkpointable source, briefly pauses it to save memory
and clone disk chains, then resumes it. The lifecycle lock is released once capture
owns its inputs; packing and transfer may continue. Never stop a source merely to
prepare this capture: stopping loses the memory you wanted to save.

Supported disk state includes `/workspace`; a RAM file such as
`/dev/shm/prepared-table` also survives restore. Host mounts and external resources
are outside the contract. The host must finish preparation commands and verify
there are no user workloads, credentials or external connections waiting to resume.
`idle: true` is this explicit host assertion. An empty command slot does not prove
idleness: a background process may still run. SmolBox cannot inspect arbitrary
process memory to prove it contains no secrets.

Capture preserves source identity and leaves it running on success. It is not a
stop/start cycle. Restoring creates a new managed identity and independent disks;
changes to one restore must not modify the capture or source. A later normal stop
and start of a restored guest is not another memory restore. Create a new machine
from the checkpoint when you need the captured memory again.

## Approve capture storage and resources

```elixir
{:ok, policy} = SmolBox.CheckpointPolicy.new(
  id: "private-captures",
  root: "/srv/smolbox/checkpoints",
  max_bytes: 1_073_741_824,
  resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 16}
)
```

Register this exact value in the owning worker's `checkpoint_policies`. The numbers
are illustrative for a small guest, not universal sizing. The root is an existing
private directory on the **controller host**, with no group or other permissions.
Every controller sharing a store must see the same protected filesystem at that
path. Host permissions must protect parent directories and prevent symlink races.
Do not put captures in a public static-assets directory or source repository.

The controller streams bounded chunks to an exclusively created private file,
hashes the complete received bytes, syncs them, and publishes the complete filename
without replacing existing output. A unique directory derives from the scoped
request fingerprint. Partial files remain for investigation after failure; no
file is automatically adopted after a lost result. The library does not load the
whole checkpoint into memory or extract it. Custom transports must implement the
bounded `{:file, io_device}` response mode without buffering or replay.

The byte cap bounds controller output, not worker capture staging. Admission
reserves additional resources and checks a source-sized disk floor covering two
disk copies, guest RAM and output allowance. Actual assets, compression, sparse
files and worker settings can require more. These are conservative declarations,
not host filesystem or memory quotas; qualify and enforce host limits separately.
Capture does not request upstream prepared-cache retention. External caches and
extra retained copies remain the host's responsibility.

Configure both worker `operation_timeout_ms` and `receive_timeout_ms` for the
approved capture duration. Their ordinary defaults are too short for many captures.
The capture timeout defaults to 15 minutes and can be set from one second to 24
hours. `await/3` accepts up to 15 minutes per wait; repeat reads/waits for longer
operations. A timeout ends observation, not worker activity.

## Capture and inspect

After creating and starting an opted-in source and completing preparation:

```elixir
{:ok, request} = SmolBox.CheckpointCaptureSpec.new(
  id: "prepared-v1", policy: policy, idle: true, timeout_ms: 900_000
)
{:ok, handle} = SmolBox.Checkpoints.capture(runtime, machine_handle, request)
{:ok, capture} = SmolBox.Checkpoints.await(runtime, handle, 900_000)
{:ok, same_record} = SmolBox.Checkpoints.fetch(runtime, handle)
```

A handle is `{scope, machine_id, capture_id}`. Hosts authorize every scope; possession
of a handle is not authorization. Repeating an identical request returns its
original handle, including after source deletion or artifact release. A changed
specification under the same identity conflicts. At most 256 captures are retained
per machine; history is never evicted to admit more.

A successful fetch means a record was read. Check its state:

| State | Evidence and reservation |
|---|---|
| `:accepted` | Durable intent, not dispatched; operation slot and extra resources held |
| `:dispatching` | Request may have reached the worker; all reservations held |
| `:captured` | Complete bytes hashed and synced; operation slot and extra resources held pending host confirmation |
| `:unknown` | Capture, source state or result remains uncertain; all reservations held |
| `:completed` | Captured bytes plus explicit quiescence confirmation; operation slot released, artifact disk allowance retained |
| `:resolved_unknown` | Host established quiescence but no result was adopted; artifact allowance retained pending cleanup |
| `:failed` | Failure before a potentially effective capture dispatch; extra allowance released |
| `:cancelled` | Cancelled before dispatch; extra allowance released |

Captures exclude commands, PTYs, file operations, other captures, exports and
start/stop/delete on the same machine through atomic store admission. Controllers
sharing that store coordinate this exclusion. Direct worker requests and external
operators must respect the same authority. Capture completion never deletes the
source or releases its own reservation.

`cancel/2` cancels accepted work. During dispatch it records an unknown outcome;
it cannot terminate a worker capture. It leaves captured/terminal evidence intact.
Caller exit does not cancel durable work. A restarted controller never replays a
dispatching capture or adopts a file based on its name. A stored captured result
remains available after restart.

## Confirm quiescence and recover

Before resolution, fence requests from old controllers and establish that worker
capture, any helper work, and temporary staging are finished or explicitly cleaned.
A store lease, running/stopped observation, or controller restart is insufficient.
The supported HTTP API has no capture-status or cancellation operation that can
fence an already sent request. A failed capture may need operator intervention to
resume or stop its source. Preserve evidence and never guess that it failed safely.

```elixir
{:ok, machine} = SmolBox.Machines.inspect(runtime, machine_handle)
{:ok, completed} = SmolBox.Checkpoints.resolve(
  runtime, handle, machine.version, quiesced: true
)
```

The current source incarnation must be observed running or stopped. Ownership
mismatch or worker unavailability blocks resolution. A captured record becomes
completed; unknown becomes resolved_unknown without claiming a result or replaying.
If the operator has already deleted the quiescent source, pass
`disposition: :deleted` alongside `quiesced: true`. SmolBox verifies absence before
recording deletion and releasing the source reservation. Artifact accounting remains.

This confirmation is an operator assertion, not a remote cleanup attestation.
Only use a new capture identity after old work is quiescent. An unexpected file,
partial transfer or lost response is evidence to investigate, not a reusable source.

## Explicit independent restore

The result records whole-file SHA-256, size, controller path, exact profile,
platform, architecture and runtime. This establishes received byte identity, not
safe contents or universal portability. smolvm separately checks artifact integrity
and CPU compatibility on restore. A new Python process does not inherit another
process's imported modules just because its machine came from a checkpoint.

Copy the artifact to a protected path on the target worker if necessary, verify
the same byte digest there, and explicitly approve the captured idle state:

```elixir
{:ok, approval} = SmolBox.CheckpointResult.approval(completed.result,
  id: "prepared-v1", worker_path: "/approved/prepared-v1.smolcheckpoint"
)
```

Register that exact approval in the target worker's `checkpoints` catalog, including
its exact profile, capture runtime and platform/architecture. This function does not
copy files or change configuration. The original source approval remains in the
catalog while its machine is managed.

Then create a new machine:

```elixir
{:ok, copy} = SmolBox.Checkpoints.restore(runtime, handle, approval,
  scope: "project", id: "prepared-copy-1"
)
{:ok, created} = SmolBox.Machines.await(runtime, copy, 120_000)
{:ok, _} = SmolBox.Machines.start(runtime, copy, created.version)
```

Wait for the running state before submitting commands. `restore/4` requires a
completed, unreleased capture, matching result identity and explicit worker
approval. Repeating the new machine identity deduplicates through the existing
managed-machine contract. It cannot overwrite the original. Creation uncertainty
uses existing machine recovery and never creates a replacement under a lost identity.
There is no cross-version, cross-platform or cross-CPU portability promise.

## Retention and release

Source machine disks, checkpoint bytes, and restored machine disks have separate
lifetimes. Deleting source or copies does not delete checkpoint bytes. Captured or
unknown work holds full extra capacity until resolution. Completed/resolved records
retain a rounded-up `max_bytes` disk allowance against the original worker, even
when the controller filesystem is separate and after the source is deleted.
This is logical conservative accounting; the host budgets the actual filesystems.

After explicit deletion of all retained copies and partial output:

```elixir
{:ok, released} = SmolBox.Checkpoints.release(runtime, handle,
  artifacts_removed: true
)
```

The controller checks that complete and partial local paths are absent. The host
asserts cleanup of other copies. The library never deletes artifacts implicitly.
Release drops only capture storage accounting and retains history and deduplication.
Independent restored machines keep their own reservations and can continue running.
No expiry or garbage collection is added.

## Persistence and upgrades

Opted-in machines and capture histories use **codec v12** and require store
capability `managed_checkpoints: 1`. Old records gain default false/empty fields
on read; their prior encodings and fingerprints remain unchanged. Older envelopes
cannot carry the new fields. The memory adapter and encrypted PostgreSQL example
implement atomic capture history, exclusion and retained disk accounting.

**No SQL migration is required**, but upgrade all controllers, readers and resource
projection writers sharing the store before creating opted-in machines. Mixed
versions are unsupported. Older readers cannot decode v12 or account for retained
captures after source deletion. Rollback requires a compatible reader or a coordinated
pre-feature backup after worker effects are quiescent; never strip history to force
an old reader to accept it. The community example conditionally omits this capability
when using its older published library dependency.

The [durable example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#managed-checkpoint-capture-and-restore)
runs capture, confirmation, restore and release in separate BEAM processes. The
[Linux evidence](evidence/managed-checkpoints-linux.json) records a real 1.19.0 bare
guest campaign with PostgreSQL, disk and RAM markers, independent restores, source
preservation, deletion and retained artifact accounting. Simulated failure tests
cover lost responses, store failures and controller restarts; those are not
power-loss or production filesystem durability qualification. macOS managed capture
has not been live-qualified in this campaign.

The [1.20.2 qualification](runtime-1.20.2-qualification.md) records the newer
worker campaign separately from the original feature evidence above. Preserve the
exact capture runtime on checkpoint approvals; changing a filename or version
field does not migrate saved machine state.
