# Create managed branches

A branch creates another running machine from a prepared source, including its
memory and disks. Prepare once, then give separate tasks their own copies. Changes
to one child's guest memory or disks do not change its siblings or source.

This first contract supports **idle, offline bare guests on smolvm 1.19.0, 1.20.2 or 1.22.0**, on the
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

**For the HTTP backend, an uncertain release cannot be resolved as kept.** Upstream can clear its held
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

HTTP branch children and sources with branch history use **codec v13** and require
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

Embedded Port branch support is still under implementation and public admission
remains disabled. Its frozen child assignments and source dependency/history
records use **codec v30**, including original completion, immutable child root and
current held/released material. Source commands carrying branch material links
use v29; commands retaining a native child assignment use v30. Completion and
explicit kept resolution require both the original proof and matching current
source/child observations. These readers preserve earlier HTTP/native bytes and reject new branch
semantics in older envelopes. Upgrade every shared reader and resource writer
before future activation. Codec support alone does not enable native branching
or establish ordinary platform qualification.

Explicit native held-release intent, proof and attached commands use **codec v31**.
The store freezes the original release version, a fresh request/deadline, current
source head and both process identities, then updates source and child together.
An uncertain attempt keeps both locks and charges until explicit resolution.
Earlier v30 records retain their bytes and gain an empty release default on read.
The native backend now routes creation, explicit held release and retained-result
lookup through the Port protocol. It validates the original proof and then obtains
fresh source and child observations under one pinned helper owner and absolute
deadline. Runtime completion updates the source/child pair atomically. Explicit
kept resolution can consume an original completed release proof; an absent proof
or the held flag alone cannot authorize success, replay or capacity release.

Public native admission remains disabled. Before future activation, every shared
reader and paired resource writer must support the native lifecycle and advertise
`native_branches: 1` together with `managed_branches: 1`. Current built-in stores
intentionally do not advertise the native marker. Routing and codec contracts do
not establish SDK release, cleanup or ordinary platform qualification.

Native dependency retirement now consumes that fenced child-absence proof in
one source/child transaction. The child must already be durably deleted. The exact
request binds its saved completion/head, fingerprint and observed child version;
a changed child version invalidates a result even while the source guard is valid.
The helper fence remains held through proof collection and final store commit.
Success marks only the matching source dependency retired and preserves material,
creation history and every extra backing charge. Bare absence or an SDK row alone
cannot substitute. An identical completed retirement remains idempotent.

The retained proof and original child version selectively use **codec v32**.
Earlier v30/v31 bytes retain their envelopes and acquire an empty retirement field
on read. Earlier experimental retirement states remain readable but cannot supply
the new evidence; explicit ratification requires fresh fenced proof. Upgrade all
readers and paired resource writers together before native activation. Ordinary
backing-release qualification, remaining partial/absent creation resolution and
normal replacement qualification remain pending. Public native admission is still disabled.

Original held-child deletion also retains independent observational, continuation
and residual-cleanup requests. `Machines.resolve/4` confirms absence without
sending SDK delete or file cleanup. Explicit `Machines.continue_deletion/4` can
finish only an unentered final SDK delete after original collection;
`Machines.cleanup_deletion/4` removes residual original files after SDK
row/reservation absence and sends no SDK shutdown/delete. Both require
`quiesced: true`, the current inspected version and the retained original helper
context. An entered SDK delete never replays. Requests and typed acknowledgements
use **codec v35**; earlier codec bytes retain their shape. Upgrade every reader
and resource projection writer before activation.

Each public action keeps the original helper/controller fence through durable
acceptance, bounded IO and final guarded commit. Explicit retries keep the accepted
request. A saved matching acknowledgement returns without contacting a helper;
missing or late evidence retains the child slot. Another action's incomplete
request remains history after completion and cannot be reused for fresh IO.
Success releases only ordinary child capacity. Dependency retirement and backing
release remain separate. Native branch admission stays disabled until the
remaining lifecycle and ordinary qualification requirements are satisfied.

Original published children that never entered boot have a separate disposal
path. `Branches.resolve/3` with `disposition: :deleted` requires the retained original context
and a positive typed candidate before accepting disposal; it never invents a
Machine or boot completion. Disposal intent/result uses **codec v37**. After
fresh fenced absence, `Branches.retire/3` saves its distinct proof in **codec v38**
and retires only the source dependency. Extra backing stays charged.

After source deletion, retirement of every dependency and host-confirmed file
removal, `Branches.release_storage/3` accepts a stable original-disposal request in
**codec v39**. The original source scope and helper/controller fence cover
acceptance, bounded native accounting acknowledgement and paired closure. A
`:backing_pending` child retains its full extra allowance until that exact typed
acknowledgement is saved. Missing replies and failed commits preserve the request;
explicit retries use the same identity, and saved completion returns without
helper IO. The call performs no filesystem deletion. Disposal and retirement
history remain immutable after closure. Every shared reader and resource writer
must support v37–v39 before future activation; native branch admission remains
disabled pending the remaining lifecycle and ordinary platform qualification.

The shared engine's ordinary delete path now also handles an originally
handed-off released child. Its exact completed initial/explicit release, original
manager/enrollment and current owned head must qualify before collection and SDK
deletion. A separate native protected journal schema records this origin; legacy
held recovery cannot consume it. Source/snapshot backing and its allowance remain
retained. This path still needs ordinary SDK/platform qualification.

An uncertain released-child delete currently requires a distinct native recovery
proof that is still under implementation. `Machines.resolve/4` rejects that case
before helper fencing; generic namespace absence and held-only proof cannot free
its reservation. Restarted and pre-handoff child deletion also remain pending.
These boundaries do not enable public native branch admission.

For initial creation uncertainty, explicit kept resolution can finish the
handoff of already completed original initialization/release:

```elixir
{:ok, kept} = SmolBox.Branches.resolve(runtime, child_handle,
  quiesced: true,
  disposition: :keep
)
```

The original manager, enrollment, protected completion and frozen creation must
still qualify under the original helper. One finite deadline and helper/controller
fence cover native handoff, fresh source/child observations and the paired commit.
Boot, initialization and activation never replay. Missing/late/mismatched evidence
or a failed commit retains uncertainty, source exclusion and all reservations.
Explicit retry uses the same creation identity, draining allows recovery, and an
already saved kept result returns without helper IO. The child keeps an immutable
creation root separately from its current observation. Existing codec v30 covers
this completion; no new schema or SQL migration is needed. Ordinary SDK/platform
qualification and other partial/deletion paths remain pending, so native branch
admission stays disabled.

See the [durable example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#managed-branches)
for separate-process creation, restart, isolation, held release and cleanup. The
[Linux evidence](evidence/managed-branches-linux.json) distinguishes real worker
results from simulated failure tests. No cross-worker, cross-platform or macOS live
qualification is implied.

See [Supported platforms](supported-platforms.md) for current worker selection
and [Testing reports](testing.md) for recorded checks and their limits.


Released-child deletion now has a distinct checked native absence proof and Port
exchange for both initial and explicit release. It requires original retained
completion/deletion context and positive original collection plus SDK namespace
absence; it performs no SDK deletion or file removal. Public deleted resolution
now persists a distinct released intent before native IO and consumes its exact
proof under the same helper/controller fence. Selective codec v40 freezes claimed
record/delete versions, original completion, release and current head. Resolution
releases only the ordinary child reservation; source dependencies and backing
require their separate cleanup. Missing, bare, held-only or mismatched evidence
keeps uncertainty and its reservations. The shared engine and Port also have a
distinct continuation for an originally collected child's unentered final delete;
entered SDK deletion never replays. Public continue_deletion now freezes a distinct released grant before IO and
consumes its exact SDK-success acknowledgement under one helper/controller fence.
Selective codec v41 preserves the grant and original delete version across retries;
absence resolution keeps a pending continuation without claiming SDK success.
Only the ordinary child reservation retires. The shared engine and Port also
provide residual cleanup after original collection and SDK namespace absence,
preserving source/backing and link targets without SDK deletion replay. Its
separate recorded grant bounds partial cleanup and retains metadata through
quarantine. Public `cleanup_deletion` now saves a distinct released cleanup grant
before native IO, under the same captured helper/controller fence through guarded
completion. Selective codec v42 preserves that request and its typed absence proof.
Cleanup, observation and SDK continuation retain separate requests; completing any
one preserves the others as pending history. Only the ordinary child reservation
retires; dependency and backing closure remain separate. Upgrade every shared reader
and resource projector before using v42. Older envelopes reject it, and records
without this grant keep their earlier encodings. Restarted/pre-handoff deletion
and ordinary SDK/platform qualification remain pending.
Native branch admission and ordinary SDK/platform qualification remain pending;
crash validation stays deferred.


Normal stop of an original released child now uses the same original-manager
collector as explicit deletion. A pending SDK stop entry keeps collection fenced
until the call returns, and only positive collection permits acknowledging the
exact stopped row and retiring its active manager handle. SDK errors, changed rows
or incomplete collection retain uncertainty. Protected release/material history
remains available for ordinary restart; source dependencies and backing stay
reserved. This is an implementation foundation with deterministic checks; native
branch activation and ordinary stop/restart/delete qualification remain pending.


A normally stopped child at its exact original released material head now returns
to the protected branch deletion path when the same helper still retains its
original completion and collected manager context. This also covers that unchanged
head after an ordinarily completed restart and stop. No active handle/manager,
canonical stopped state, current epoch quiescence and positive original collection
are required before the delete intent is entered. Final SDK deletion, explicit
continuation, absence resolution and residual cleanup use the existing journals
and proofs, retaining source dependency and backing charges separately. A stopped
row alone cannot provide this authority. Later material heads, active handles and
replacement helpers keep their existing lifecycle behavior; complete recovery for
those paths and pre-handoff deletion remain pending. These deterministic contracts
do not qualify live stop/restart/delete or enable native branch admission.


Ordinary SDK starts now retain their returned boot enrollment and finite metadata
charge in the current helper. Stop also cleans up an already exited child instead
of treating a missing direct-manager entry as sufficient completion. SDK stop and
ordinary deletion keep collection fenced until the call returns, then require
positive collection; unknown results retain their original authority and charge.
A later start first cleans the previous returned boot under the same ownership
checks. This preserves the path from normal restart/stop to protected original-head
deletion. Native branch activation and live lifecycle qualification remain pending;
no boot ownership is reconstructed from SDK inventory or a replacement helper.


Embedded stop now carries the remaining caller deadline and cancellation through
preflight, read-only observations, original/current boot collection and final
acknowledgement. Expiry before SDK entry prevents dispatch; expiry after entry
keeps the result uncertain. A failed final observation retains the current boot
slot and active handle so an explicit retry can complete cleanup. A later bridge
timeout still cannot convert completed local collection into a public stopped
acknowledgement. The existing error vocabulary, VM storage and separate backing
charges remain unchanged. Ordinary package/platform qualification is still pending.


The separate original-child collection control is exposed as
`SmolBox.Machines.collect_deletion(runtime, child_handle, version, quiesced: true)`.
It requires the inspected version and retained original helper/completion/boot
context. The controller holds the helper fence while saving the exact independent
request, calling Port and committing its typed acknowledgement. A matching saved
acknowledgement returns without helper IO; retries retain the original request.
This proves historical collection only. Deletion stays uncertain, every ordinary
child/dependency/backing reservation remains charged, and SDK rows, readiness and
namespace absence gain no authority. Use `continue_deletion/4` separately for the
unentered final SDK delete; an entered SDK delete never replays.

The independent collection history uses **codec v43**. Earlier records retain their
exact envelopes/bytes, with a nil collection default on read. Upgrade all readers
and resource projection writers before activation. An additional 128-KiB native
metadata reservation is retained before original deletion entry so collection
control remains available during quarantine. Ordinary SDK/platform qualification
remains pending; native branch admission stays disabled and crash validation is
deferred.
