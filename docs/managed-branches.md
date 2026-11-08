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

For HTTP, keeping a child requires a previously persisted creation response and matching
source and child incarnation evidence. Upstream's public machine observation does
not expose immutable lineage or an ownership token. SmolBox binds a successful
response to its recorded source request and random child name; exclusive ownership
of that namespace is required. It never adopts an unknown child by name alone.

For HTTP, if the creation response was lost, establish quiescence, identify and explicitly
remove the owned worker child through operator procedures, then resolve with
`disposition: :deleted`. SmolBox verifies absence. It does not delete an unverified
machine automatically. Worker unavailability is never absence. If both source and
child disappeared, resolution marks the source missing and retains its reservation;
retire child dependencies before explicitly resolving the source deletion through
`Machines.resolve/4`.

The embedded backend can also recover a completion retained by the original
helper when the managed creation response was not committed. It requires the
exact saved creation request, the same original owner/epoch, fresh source and
child observations and a paired store commit. It never adopts a child from an
SDK row or matching name. The [f56c2e3 Linux Memory case](evidence/embedded-port-http-parity-public-memory-cancel-recovery-f56c2e3.json)
passes public cancellation followed by explicit held-result recovery, preserved
draining, subsequent sibling use and owned cleanup on both installed toolchains.
The [corresponding PostgreSQL case](evidence/embedded-port-http-parity-public-postgresql-cancel-recovery-f56c2e3.json)
now passes on both installed toolchains with fresh encrypted databases, the same
completed-result recovery and owned cleanup. Separate BEAMs on both toolchains
read all 13 final encrypted records and both backing acknowledgements without
native workers. Both readers validate five checkpoints (45 records) per dataset.
These cases do not identify every internal native cancellation phase. Other
partial phases, platforms and upgrades remain pending. Crash validation is deferred.

**For the HTTP backend, an uncertain release cannot be resolved as kept.** Upstream can clear its held
flag before guest activation completes, so that flag does not prove successful
release. Fence old requests, explicitly remove the child and resolve its absence.
Never replay release or start a replacement under the same identity.

## Delete, retire dependencies, release backing capacity

Embedded completed-child retirement and backing controls preserve an already
completed recovery scan only for the same healthy original helper epoch and
worker lease generation. The authority barrier spans quiescence, acknowledgement
and bounded reactivation. Failed reactivation leaves dispatch fenced while
preserving a committed acknowledgement. Worker draining remains unchanged;
incomplete startup and partial/unbooted cleanup retain conservative recovery.
When a prior Port record is still draining, ordinary controls wait for quiescence
within the same captured deadline and native authority barrier. Only a known
busy/not-dispatched fence reply can be retried; native work and uncertain bridge
replies are never replayed. The
[drain correction](evidence/embedded-port-http-parity-branch-quiescence-drain.json)
has source/model coverage; changed-source installed acceptance remains required.
The [correction evidence](evidence/embedded-port-http-parity-branch-control-readiness.json)
covers models and store contracts. The subsequent
[9470074 Linux local-bare Memory campaign](evidence/embedded-port-http-parity-public-branches-9470074.json)
passes both installed current/minimum consumers. The subsequent
[c5f9fde PostgreSQL case](evidence/embedded-port-http-parity-public-postgresql-branches-c5f9fde.json)
also passes the completed lifecycle and encrypted historical readback with both
toolchains. On macOS ARM64 with minimum Elixir and PostgreSQL, the scoped
[partial branch case](evidence/embedded-port-http-parity-macos-durable-partial-4c3dcf63.json)
and [unbooted case](evidence/embedded-port-http-parity-macos-durable-unbooted-0618e7cc.json)
verify public disposal, retirement, backing release and workerless history
readback with explicit qualification helpers. The
[Linux durable recovery cases](evidence/embedded-port-http-parity-linux-durable-branch-recovery-32d4b083.json)
verify the same local-bare paths on current and minimum Elixir with PostgreSQL
16.15. Wider source and resource combinations still require evidence.

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

Embedded Port accepts approved Linux checkpoint/branch descriptors only with
complete native store readers and paired resource writers. Memory and the
PostgreSQL example advertise `native_branches: 1`; the linked Linux local-bare
Memory and PostgreSQL public campaigns above have current/minimum ordinary acceptance. Other
platforms and optional cleanup-resolution remain gated. Each child's dependency
and backing allowance has an independent
lifetime: cleaning up one sibling does not unblock source lifecycle while another
dependency remains, or release another child's backing. The paired-store sibling
contracts cover these accounting boundaries; ordinary VM independence and exact
package qualification remain required. The
[sibling accounting evidence](evidence/embedded-port-http-parity-branch-siblings.json)
records the validated scope.

The following native integration notes record successive codec and recovery
checkpoints. Statements that admission was disabled describe those earlier
snapshots; current admission and qualification are scoped above.

For an ordinary encrypted PostgreSQL campaign, the durable example provides
`examples/durable_host/scripts/embedded-branches.exs`. Use a fresh account/domain,
the approved Linux bare artifact/package, the example's configured database and
a toolchain PATH without Cargo or rustc. Its private settings JSON supplies
`package`, `manifest_sha256`, `domain_json`, `artifact`, `artifact_sha256`, `scope`,
`partition`, `encryption_key_file` and `fingerprint_key_file`; both key files hold
32 bytes. Keep the same keys and partition for readback. Migrate the example's
database before the first phase.

```sh
cd examples/durable_host
MIX_ENV=prod mix run scripts/embedded-branches.exs --ordinary --without-rust \
  --phase exercise --settings /private/branches/settings.json \
  --output /private/branches/exercise
```

After this process exits successfully and its ordinary native shutdown completes,
start a separate BEAM to compare every saved final machine/command record through
the public read APIs and read both completed backing acknowledgements:

```sh
MIX_ENV=prod mix run scripts/embedded-branches.exs --ordinary --without-rust \
  --phase readback --settings /private/branches/settings.json \
  --expected-records /private/branches/exercise/private-records-completed.json \
  --output /private/branches/readback
```

Readback configures no workers and cannot launch SDK work. It preserves durable
records and checks zero reservations. An exercise failure retains its original
Runtime/store for explicit inspection and cleanup; never start another exercise
or readback to bypass that state. The linked c5f9fde campaign now qualifies this
exact Linux local-bare workflow, including both encrypted cross-toolchain readers
with the same library version. It does not qualify library rollback or other
source/platform/partial-recovery combinations. It selects no crash validation.

Its frozen child assignments and source dependency/history
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

The separate pre-handoff collection control is exposed as
`SmolBox.Branches.collect_partial(runtime, child_handle, version, quiesced: true)`.
It applies only to an uncertain original embedded creation whose source still
retains the exact creation head and active dependency. It needs the original
helper's retained manager/enrollment; an SDK row or matching name supplies no
substitute. The current controller/helper epoch is fenced before an immutable
full-creation/action request and pinned platform are saved. Its control budget is
at most 30 seconds, 21 KiB encoded input allowance and six KiB reply allowance,
including framing headroom. Collection never boots or initializes the child.

A matching acknowledgement records only original-child collection. The child
remains unknown, and every ordinary reservation, source dependency, disk and extra
backing allowance stays charged. Exact saved acknowledgement reads return without
helper IO. A missing reply retains the same accepted request for explicit retry;
only the original manager's cached acknowledgement can deduplicate completed
collection. A stale child version, crossed platform or failed commit cannot
publish completion. This action cannot turn collection into readiness, absence,
deletion, never-booted disposal or prepared-only retirement. The shared engine and
Port protocol have distinct pre-handoff disposal controls and typed readers. Their
terminal handoff retains the exact synchronized proof, original runtime/domain,
opaque child enrollment and native backing while releasing only transient work
and source/child locks. Exact historical lookup cannot replay SDK deletion or
adopt newly recreated child material. Memory and encrypted PostgreSQL now provide
paired disposal acceptance/completion writers and selective codec v45 readers.
The separate action retains the completed collection and pinned platform, and
only a matching current-version disposal result plus fresh source observation
can release ordinary child capacity. Source dependency and extra backing stay
charged. Upgrade every reader/projector before advertising
`native_partial_branch_disposals: 1`; this marker enables no branch feature.
`SmolBox.Branches.dispose_partial(runtime, child_key, version, quiesced: true)`
now saves and dispatches this separate action under the same controller/helper
fence as its paired commit. `resolve/3` with `disposition: :deleted` selects the
same path when a collection record exists; its acknowledgement is required before
any disposal. An accepted retry first observes its original disposal. An uncertain
observation never falls through to another deletion offer. Only a definitive
not-dispatched state reply may offer the same request to the engine's one-shot
grant, which independently prevents repeated SDK entry. Lost proof/source replies
and failed commits retain the accepted request and every public reservation.
Saved disposal and collection acknowledgements return the current record without
helper IO. A separate engine/Port `cleanup_partial_branch_disposal` control and
strict typed reader now cover original SDK-absent residual cleanup. Its distinct
request and resolved-absent acknowledgement preserve collection/disposal history;
only the original cached/protected removal grant may remove the original child
subtree. The bounded control requires explicit quiescence, exact branch approval,
Delete capability and matching platform/domain/original epoch. It never retries
SDK deletion or retires dependencies/backing. Memory and encrypted PostgreSQL now
freeze a separate nested cleanup request before IO and commit only its matching
typed acknowledgement plus fresh source observation. The distinct
`disposal_cleanup_pending` phase and selective codec v48 retain every reservation
while pending; ordinary disposal cannot consume this action. Completion records
both cleanup and resolved-absent disposal together, releasing only ordinary child
capacity. Dependency/backing closeout remains separate and preserves cleanup
history. Upgrade every reader/projector before advertising
`native_partial_branch_cleanups: 1`; this marker enables no native branches.
`SmolBox.Branches.cleanup_partial(runtime, child_key, version, quiesced: true)`
now holds one controller/helper fence through durable acceptance, bounded cleanup
IO, fresh source observation and paired completion. It applies to the original
SDK-absent residual state; the engine independently requires original retained
ownership and the exact protected removal grant. Its cleanup/observation stage
uses at most 32 KiB encoded input and 96 KiB reply data, including envelope
headroom. The fresh qualification and total workflow bounds are described below. An accepted retry uses the same cleanup request, with no SDK disposal
fallback. Deleted resolution resumes an already accepted cleanup; it does not
create one from bare absence. Saved acknowledgements, including later retirement
and backing closure, return without helper IO. A late store acknowledgement stays
uncertain; an actually committed matching proof can then be read normally.

Native eligibility/recovery now has a separate
`qualify_partial_branch_cleanup` engine/Port control and strict reader. It can
return a positive original residual candidate, or the exact original terminal
disposal with its existing provenance. Positive original SDK row/reservation and
directory absence can resolve the prior disposal without creating cleanup.
A candidate is no cleanup/disposal proof or capacity-release grant. A current row,
reservation, changed original directory, other owner or missing/crossed history
refuses qualification. The public coordinator now runs this check before
accepting fresh cleanup. Only a positive candidate permits the new action, after
reserving its complete cleanup/observation budget. If the original disposal is
already terminal, fresh source observation and guarded paired completion record
that exact result without accepting cleanup. Deleted and ResolvedAbsent remain
distinct. Refused, unknown, malformed or expired qualification cannot create a
grant. Already accepted cleanup skips fresh qualification and keeps its saved
request. The workflow shares one 30-second deadline and aggregate 64-KiB input /
192-KiB output cap; its qualification stage uses 26/64 KiB and cleanup plus source
observation uses 32/96 KiB. Saved ordinary disposition remains readable through
retirement/backing closure, using the original pending completion version or
current version, without another helper call. Other partial phases, recovery of
previously accepted unsupported grants and ordinary rebuilt-package qualification
remain unfinished; public native branch admission remains disabled.

Original partial disposal now has a separate protected SDK-entry fence. A saved
primary Entered intent alone never proves deletion unentered. Only the original
cached grant and matching protected Prepared sidecar, together with fresh exact
row/source/root/collection checks, permit the first SDK deletion call after an
accepted intent whose worker never entered it. A retry offers only that same
saved action. The cache is consumed before the Entered write and SDK call; an
uncertain write or SDK error cannot authorize another call. Missing caches,
missing/rolled-back published sidecars, changed ownership and existing residual
cleanup refuse SDK continuation. No manager or grant is reconstructed from files
or empty inventory. Positive original absence can still resolve the old disposal.
A matching visible primary intent whose original publication was not acknowledged
can now recover after fresh exact row/source/root/lifecycle/collection validation.
Its original unused SDK-entry cache and absence of any entry/cleanup sidecar are
required. Recovery synchronizes existing intent bytes before acknowledging the
original cache; it never replaces intent or creates an SDK grant from files.
Missing legacy caches, entered/attempted SDK state and absent/changed context
refuse recovery. Other partial phases remain required; this does not qualify an
SDK/VM or changed package or enable public branches.

The shared engine additionally has a distinct acknowledgement for cleanup that
was accepted after original disposal already completed. It requires the original
terminal owner's positive unused-cleanup cache provenance and protected history:
cleanup was never enrolled, or its exact original exclusive cache proves that
publication was never attempted. An attempted/published cleanup cannot become
unused because its receipt is missing. Both Deleted/ResolvedAbsent provenance
remain intact without claiming residual removal. Before acknowledgement, an
unarchived terminal disposal can now finish its original handoff using the
retained manager/actor, exact published intent and protected terminal proof.
Selection and handoff revalidate unused provenance separately under the same
captured budget, without stacking material controls. Missing original owner or
terminal proof, competing actors, wrong cache requests and foreign cleanup history
refuse recovery. No manager is reconstructed or SDK lifecycle work dispatched;
new SDK occupants/files are left untouched. If the original primary is still
Entered, its exact exclusive enrolled-but-unattempted cleanup can now use a
separate positive-absence completion. Under the original work lock, it verifies
both SDK row/reservation and directory absence twice, source authority and
unchanged source/material/retained roots, and exact original cache/actor history
before publication. Recreated rows, handles, paths or changed source refuse
completion. It publishes only ResolvedAbsent, then reuses the terminal handoff
and distinct acknowledgement. A missing/used cache or bare empty namespace cannot
complete disposal. This path never grants removal or repeats SDK deletion. The explicit protocol-two
`resolve_partial_branch_cleanup` Port operation and strict Rust/Elixir readers
now carry that distinct acknowledgement. It requires Inspect, the exact branch
catalog and optional `partial_cleanup_resolution: 1` together with `branches: 1`;
older helpers without that feature reject before dispatch. The feature remains
unadvertised/unapproved in default packages. Reserved control/output and one
30-second deadline preserve 28-KiB request/80-KiB proof limits. The removal
command cannot return or consume this alternate proof. Reader-first paired
Memory/PostgreSQL history now consumes a distinct typed resolution result beside
fresh source observation. It records `cleanup.unneeded` separately while
`cleanup.proof` remains nil, preserving the accepted request and original disposal
provenance. Only ordinary child capacity retires; dependency/backing closeout
remains explicit. Selective codec v49 carries this history through later cleanup;
older pending/removal records retain v48 and omit exactly the new nil default.
Upgrade every reader/projector before advertising
`native_partial_branch_cleanup_resolutions: 1`; this marker enables no branches.
The existing public cleanup/deleted-resolution flow now consumes this distinct
acknowledgement under the same controller/helper fence. It offers the saved cleanup
control first. Only a strictly valid zero-output native `not_dispatched` terminal,
plus the negotiated optional capability, allows original-history lookup. Direct
transport errors, uncertain replies, malformed results or legacy helpers cannot
trigger it. A negative lookup retains the pending action and every charge; it
never falls through to removal or SDK deletion. Each control stays within 32-KiB
input / 96-KiB output, and actual encoded first-refusal bytes are deducted before
lookup. Accepted retries share at most 64/192 KiB and one 30-second deadline
through lookup, fresh observation and paired store acknowledgement. Smaller
configured budgets remain smaller and can refuse another request before IO.
Fresh qualification/cleanup keeps its existing reserved stage allowances. Saved
acknowledgements remain readable using the saved acceptance/completion or current
version, including after retirement/backing closure, without helper IO. Ordinary
package qualification and the other partial SDK phases remain open; public native
branch admission stays disabled.

The paired store boundary also represents original collected material publication
separately from child completion. Acceptance freezes the full creation request,
including any initial release, explicit quiescence, platform and child version.
A typed publication plus a separate fresh source observation advances source
material history once. Both managed states remain unknown, the source stays
locked to the active branch, and all ordinary capacity, dependencies and backing
remain charged. Later ready or disposal proofs must match that same publication.
Selective codec v50 retains the action and acknowledgement; earlier envelopes
omit/restore exactly `collected_publication: nil`. Upgrade every reader and
projection writer before advertising `native_collected_branch_publications: 1`.
That marker adds no native feature. `SmolBox.Branches.publish_collected/4` now
coordinates the explicit action with the expected child version and exactly
`quiesced: true`. Acceptance, publication, fresh source observation and paired
commit share the original controller/helper fence and one deadline of at most
30 seconds. Each attempt has at most 24 KiB input / 84 KiB output; the publication
exchange consumes those totals before observation. Late or malformed replies,
wrong epoch/platform/PID, missing observations and store failures retain the
accepted request and every charge. Explicit retries use that same frozen request
against the retained original owner; no fork, boot, initialization or deletion
is replayed. Already saved acknowledgements return without helper IO, including
after later ready/disposal completion. Later ready and disposal controls consume
the exact stored material history once. Known publication skips prepared-only
retirement and still requires positive original unbooted-disposal selection;
publication alone grants no disposal authority. Ordinary package/platform/source
qualification and installed consumers remain required; public native branching
is disabled.

For an original collected preparation that never entered child boot, publish its
collected material before requesting deleted resolution. Select partial collection
only after establishing the original boot/initialization phase; managed `unknown`
alone does not establish that phase. An inapplicable collection can leave its
accepted managed intent pending without a native proof, with every charge retained.

The native [shared-cache correction](evidence/embedded-port-http-parity-unbooted-empty-cache-guard.json)
also permits the owned, empty private `pack` directory produced by SDK shared-pack
lease copying. The SDK has no layers mount or lease to process in that empty
directory. Nonempty/unsafe directories still reject, and cache shape supplies no
ownership, collection or absence proof. Corrected-package ordinary acceptance
remains required; the recorded failed owners closed normally with all charges
and SDK rows preserved.

A separate engine/Port `qualify_partial_branch_child_absence` observation is now
implemented for the positively disposed original child. It requires the exact
terminal archive/runtime/domain/ledger, retained opaque enrollment and current
original epoch. It checks actor collection and the child row, creation reservation
and original directory before and after issuing its distinct typed proof. The
source may remain running. Recreated names, current ownership handles, busy gates
or ownership registries, missing history and expired/cancelled requests reject.
Nothing is adopted, stopped or deleted; dependency and backing charges remain.
Its strict Rust/Elixir readers and synthetic fixtures do not establish ordinary
SDK/platform qualification. `SmolBox.Branches.retire(runtime, child_key, quiesced: true)`
now consumes this fresh proof under the same controller/helper fence as the paired
Memory/PostgreSQL commit. The request binds the current child version and exact
saved disposal; source identity, platform and original helper epoch must match.
Only the source dependency retires. Extra backing remains charged, and a proof
from completed-child or never-booted disposal cannot close this origin's backing.
Stale/lost replies and failed commits retain the dependency; explicit retries
require fresh observation. Saved retirement, disposal and collection acknowledgements
remain readable without helper IO. Selective **codec v46** persists retirement
without relabeling disposal-only v45 records; older tags reject the new proof.
Upgrade every reader/projector before advertising
`native_partial_branch_retirements: 1`. This marker enables no native branch
admission. Ordinary exact-package qualification of backing closure
remains required.

Pending and acknowledged pre-handoff collection records use **codec v44** and
require the `native_partial_branch_collections: 1` reader marker. Earlier records
omit the new nil field exactly and retain their existing envelope bytes. Upgrade
all readers and resource projection writers before any native branch activation;
the marker alone enables no helper feature or public branch admission. Memory
and the encrypted PostgreSQL example implement the paired source/child contract.
The HTTP backend rejects this native-only control before transport IO.


The shared engine now has a separate
`Engine::release_partial_branch_backing_checked` boundary for this original
collected/disposed origin. Its exact request includes disposal and expected
source/child material heads, explicit quiescence and host backing-removal
confirmation. The original terminal archive/runtime/domain/ledger and opaque
child enrollment remain mandatory. Source and child must be positively collected;
source/child SDK rows, creation reservations and original directories must be
absent twice under paired gates. Only the original native backing charge retires,
after the protected acknowledgement is synchronized; sibling charges and result
metadata remain. Expected source heads correlate with durable tombstones and are
never reconstructed from namespace absence. An exact saved acknowledgement does
not re-observe or clean up new namespace occupants.

The protocol-two Port now routes `release_partial_branch_backing` to this exact
engine boundary. It requires Inspect capability, the branch feature, exact
approval catalog, platform/domain/original epoch and zero output. Strict Rust and
Elixir readers bind the full request and matching accounting acknowledgement;
they retain the existing `BranchBackingRelease` result shape.

`SmolBox.Branches.release_storage(runtime, child_key, backing_removed: true)` now
coordinates partial-child backing closure after source deletion and retirement of
all child dependencies. The same controller/helper fence spans durable acceptance,
bounded native control and paired completion. The exact disposal, retirement,
source/child heads and action version remain immutable across claims/retries.
Pending `backing_pending` records retain the full extra charge. Only the matching
typed acknowledgement closes the child and releases its extra allowance in the
same transaction. Missing/late replies and failed commits retain the accepted
request; explicit retries use that same intent. Saved closed, collection, disposal
and retirement acknowledgements remain readable without helper IO.

Pending and acknowledged partial backing use **codec v47**; retirement-only v46
and earlier encodings retain their envelope/default shape. Older tags reject the
new action. Upgrade every reader/projector before advertising
`native_partial_branch_backings: 1`. Memory and encrypted PostgreSQL implement
this paired contract, including deterministic rollback checks. These models and
framed in-process peers supply no ordinary SDK/package qualification. Public
native branch admission remains disabled until the remaining lifecycle and
qualification gates pass; no helper feature activates from a reader marker.


The shared engine now also exposes
`RetainedBranchResolution::cleanup_partial_disposal` for a failed disposal whose
SDK row and creation reservation are absent while its original child directory
remains. The exact retained job, published disposal, opaque collection and source
publication are required. A separate cached, protected cleanup grant binds the
original directory and its parent before bounded descriptor-relative removal.
Partial removal resumes only that same request and original inode. It never calls
SDK deletion, removes the source/snapshot or retires dependency/backing charges.
The acknowledgement contains the original resolved-absent disposal plus the
separate cleanup request. Exact history can be re-synchronized after terminal
handoff without traversing recreated names or requiring the source to remain.

This cleanup boundary is covered by inert actor/file/SQLite models. Port routing,
typed Elixir readers and paired public cleanup actions remain required. It does
not qualify a rebuilt package or activate public native branches. An SDK retry
for a demonstrably unentered deletion still needs its own entry fence: the older
`entered` record binds intent publication and cannot establish whether the SDK
call began. Existing entered grants remain one-shot.
