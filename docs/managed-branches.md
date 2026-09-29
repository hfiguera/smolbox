# Create managed branches

A branch creates another running machine from a prepared source, including its
memory and disks. Prepare once, then give separate tasks their own copies. Changes
to one child's guest memory or disks do not change its siblings or source.

This first contract supports **idle, offline bare guests on smolvm 1.19.0 or 1.20.2**, on the
source's worker. It creates one leaf child per request. It does not add nested
branches, source freezing, migration, branch pools, network restoration or arbitrary
application cloning. A branch is a managed machine, not a Git branch or a portable
artifact. Use [exports](machine-exports.md) for supported disk artifacts and
[checkpoints](managed-checkpoints.md) for explicit saved memory and independent restore.

## Prepare and approve

Create a source with `checkpointable: true` in `SmolBox.ManagedMachineSpec`, then
start it. The source must have offline networking, no ports or startup workload,
and an approved local bare artifact or checkpoint. Checkpointable startup uses
upstream's branchable mode. Finish preparation commands before branching.

`idle: true` is a host assertion that the prepared state is safe to copy. An empty
SmolBox command slot does not prove idleness: background processes can still run.
The host must account for captured processes, credentials and external effects.
SmolBox cannot determine whether arbitrary RAM contains secrets. The API rejects
containers, networked sources, and requests to inject environment, secrets or ports.

Approve additional preparation and backing capacity on the owning worker:

```elixir
{:ok, policy} = SmolBox.BranchPolicy.new(
  id: "prepared-branches",
  resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 8}
)
```

Register this exact value in `SmolBox.Runtime.WorkerConfig.branch_policies`.
The example fits a small 256 MiB guest with 1 GiB storage and overlay disks;
qualify larger values for your workloads. Admission charges the ordinary child
allocation plus this extra allowance, while retaining the source allocation.
The minimum extra memory covers guest RAM plus configured host overhead. Minimum
extra disk covers twice the source disk allocation plus rounded-up guest RAM.
These declarations are conservative admission budgets, not host quotas or measured
copy-on-write savings. The host must enforce actual filesystem and memory limits. Shared approved source
artifacts and worker caches retain their existing, separate host-owned lifetimes.

Configure worker `operation_timeout_ms` and `receive_timeout_ms` for the expected
branch duration. The request timeout defaults to two minutes and accepts one second
to 24 hours. `await/3` accepts up to 15 minutes per wait. A wait timeout ends
observation; it does not cancel a worker request.

## Create and use a child

```elixir
{:ok, request} = SmolBox.BranchSpec.new(
  id: "experiment-a", policy: policy, idle: true
)
{:ok, child_handle} = SmolBox.Branches.create(runtime, source_handle, request)
{:ok, child} = SmolBox.Branches.await(runtime, child_handle, 120_000)
:ready = child.branch.state

{:ok, same_child} = SmolBox.Branches.fetch(runtime, child_handle)
```

The returned handle is the ordinary `{scope, machine_id}` handle in the source's
scope. Use `SmolBox.Machines.submit/3`, inspect, list, stop, start and delete with
that handle. File and terminal support follow the inherited artifact and worker
policies. Commands do not delete either machine. Source commands can resume after
branch completion. A normal child stop/start preserves disks but does not restore
its original captured RAM again.

Repeating the same request returns the original child identity, even after deletion.
Changing a request under that identity conflicts. A normal machine cannot reuse the
child ID. History is retained permanently; each source allows at most 256 child
identities, including failed and deleted requests. No eviction or automatic expiry
is added. Handles identify records; the host still authorizes access to their scope.

Creation atomically locks the source and child and reserves worker capacity.
Commands, terminals, file staging/collection, captures, exports and lifecycle work
cannot race creation through the store. Controllers sharing a store enforce the
same exclusion. External operators and direct worker calls must respect this
ownership. After creation, children can work independently. The source cannot stop,
start or delete until every child dependency is explicitly retired. Captures and
exports of branch children, or a source with unretired children, are unsupported.

## Hold and explicitly release

For a prepared guest that participates in upstream's `smolvm-branch-ready` protocol,
use `hold: true`. The host must arrange a valid guest readiness boundary before the
request. This is a specialized guest preparation contract, not a pause button for
an arbitrary running application. The durable example demonstrates the helper.

```elixir
{:ok, request} = SmolBox.BranchSpec.new(
  id: "held-experiment", policy: policy, idle: true, hold: true
)
{:ok, handle} = SmolBox.Branches.create(runtime, source_handle, request)
{:ok, held} = SmolBox.Branches.await(runtime, handle, 120_000)
:held = held.branch.state
release_version = held.version
{:ok, _} = SmolBox.Branches.release(runtime, handle, release_version)
{:ok, released} = SmolBox.Branches.await(runtime, handle, 120_000)
:released = released.branch.state
```

A held child rejects commands and start/stop. Explicit deletion is allowed.
If a held child disappears, use the existing `Machines.resolve/4` deleted
disposition after establishing quiescence and verifying absence; its backing
allowance remains until the cleanup sequence below.
Retain the submitted `release_version` when retrying the public call: that exact
version deduplicates the release. A changed version does not request a second
release. The controller persists intent before sending the worker mutation.

## Read evidence and handle uncertainty

`fetch/2` and `await/3` return managed records; success alone does not mean the
branch is usable. Inspect `record.branch.state`:

| State | Meaning |
|---|---|
| `:accepted` | Durable request, not yet dispatched |
| `:dispatching` | Worker mutation may have started |
| `:observed` | Creation response stored; source/child readback pending |
| `:ready` | Source and running child verified; child accepts work |
| `:held` | Child awaits explicit release |
| `:release_pending`, `:release_dispatching` | Release accepted or potentially sent |
| `:released` | Release response verified; child accepts work |
| `:unknown` | Outcome uncertain; operation blocked, reservations retained |
| `:resolved` | Unknown child explicitly resolved as absent; backing retained |
| `:failed`, `:cancelled` | Rejected/cancelled before dispatch; extra allowance released |
| `:retired` | Deleted child dependency retired; extra backing allowance retained |
| `:closed` | Source and child absent, host confirmed backing removal; allowance released |

The managed `state` separately records running, stopped or deleted. Deleting a
ready child does not erase its branch history or retire its backing dependency.

Caller exit does not cancel accepted work. `Branches.cancel/2` cancels an accepted
request; after dispatch it records uncertainty, retains capacity and does not stop
worker activity. Cancellation leaves a ready or held child intact. A restarted
controller never replays a potentially dispatched creation or release. It can
finish readback when the creation response was already stored.

Before resolving unknown work, fence old controller requests and establish worker
quiescence. A store lease, stopped observation or elapsed timeout cannot fence an
HTTP request already sent. The supported API has no immutable request ID or branch
status endpoint that proves a delayed request cannot still complete.

```elixir
{:ok, resolved} = SmolBox.Branches.resolve(runtime, child_handle,
  quiesced: true, disposition: :keep
)
```

Keeping a child requires a previously persisted creation response and matching
source and child incarnation evidence. Upstream's public machine observation does
not expose immutable lineage or an ownership token. SmolBox binds a successful
response to its recorded source request and random child name; exclusive ownership
of that namespace is required. It never adopts an unknown child by name alone.

If the creation response was lost, establish quiescence, identify and explicitly
remove the owned worker child through operator procedures, then resolve with
`disposition: :deleted`. SmolBox verifies absence. It does not delete an unverified
machine automatically. Worker unavailability is never absence. If both source and
child disappeared, resolution marks the source missing and retains its reservation;
retire child dependencies before explicitly resolving the source deletion through
`Machines.resolve/4`.

**An uncertain release cannot be resolved as kept.** Upstream can clear its held
flag before guest activation completes, so that flag does not prove successful
release. Fence old requests, explicitly remove the child and resolve its absence.
Never replay release or start a replacement under the same identity.

## Delete, retire dependencies, release backing capacity

1. Delete each child with the existing versioned `Machines.delete/3` operation and
   wait for verified deletion.
2. Establish that its prior worker requests are quiescent, then call:

   ```elixir
   {:ok, _} = SmolBox.Branches.retire(runtime, child_handle, quiesced: true)
   ```

   This verifies child absence and retires its dependency. It does not delete files
   or release the extra backing allowance. Once all children are retired, the source
   can stop/start or be explicitly deleted.
3. Delete the source and verify its worker backing files, snapshots and temporary
   staging are removed. smolvm can retain source generations after child deletion;
   an empty child inventory alone is insufficient.
4. Release each child's extra allowance explicitly:

   ```elixir
   {:ok, closed} = SmolBox.Branches.release_storage(runtime, child_handle,
     backing_removed: true
   )
   ```

   SmolBox verifies source and child absence and their durable deleted states. The
   host assertion covers files that the HTTP API cannot attest. Never assert it
   solely because a delete response succeeded. All history and request identities
   remain; this call only releases accounting. It performs no filesystem deletion.

The full extra allowance remains through uncertainty and retirement, including
CPU/slot headroom. This is deliberately conservative: it can limit admission even
when children have gone. The source's own reservation and any separately captured
checkpoint artifacts have independent lifetimes.

## Durable adapters and compatibility

Branch children and sources with branch history use **codec v13** and require
`managed_branches: 1`. Source opt-in also uses the existing
`managed_checkpoints: 1` capability. Existing records read with nil/empty defaults and retain
prior formats and fingerprints. Older envelopes cannot carry branch fields.
The memory adapter and encrypted PostgreSQL example implement atomic source/child
updates, identity and capacity exclusion, and accounting after deletion.

**No SQL migration is required**, but every controller, reader and resource
projection writer sharing a store must be upgraded before branch use. Mixed
versions are unsupported. Older readers cannot decode v13 or account for its
retained backing. Rollback requires a compatible reader or a coordinated backup
from before feature use after worker effects are quiescent. Never strip history to
make an old reader accept it. Custom stores must implement the full normative
`SmolBox.Store` contract before advertising the capability.

See the [durable example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#managed-branches)
for separate-process creation, restart, isolation, held release and cleanup. The
[Linux evidence](evidence/managed-branches-linux.json) distinguishes real worker
results from simulated failure tests. No cross-worker, cross-platform or macOS live
qualification is implied.

The [1.20.2 qualification](runtime-1.20.2-qualification.md) records the newer
worker campaign separately from the original feature evidence above. Preserve the
exact capture runtime on checkpoint approvals; changing a filename or version
field does not migrate saved machine state.
