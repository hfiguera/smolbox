# Clean SDK boundaries for HTTP feature parity

Baseline: SDK 1.22.0, revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. The active and comparison SDK trees
were checked against the complete source inventory before this audit. No
upstream source changed. This supplements the
[offline boundary audit](clean-sdk-api-boundaries.md) and implements the P0 audit
in the [parity plan](../docs/design/embedded-port-http-parity-implementation-plan.md).

The [checked coverage manifest](../docs/design/embedded-port-http-parity-coverage.json)
contains all 38 operations/44 signatures and eight specification features.
`test/unit/backend_parity_coverage_test.exs` compares it with actual backend
operations and adapter advertisement, validates feature references and prevents
completion claims while acceptance/evidence remain pending. Advertisement is
not behavioral qualification; all expanded feature contracts remain pending.

`tests/clean-sdk-api/src/parity.rs` compiles directly against the verified clean
SDK. Its functions are compile-only witnesses and are never invoked by tests.
Three pure configuration tests exercise public overlay-lineage/mount conversion
and offline port mapping without a database, socket, helper, VM or process loss.
The fixture adds the clean SDK's registry crate as a normal exact-version path
dependency; its source is covered by the same complete inventory.

## API and behavior map

| Feature | Callable unmodified boundary | SmolBox work required before enabling |
| --- | --- | --- |
| Health/capacity/metrics/readiness | Existing engine/domain state, public SDK records; platform/guest observations | Match public types, distinguish reserved/configured/measured data, never mutate SDK through reconciliation or instantiate a manager during observation |
| Inventory/measurements | `SmolvmDb` record APIs and supported state/agent observation | Bounded inventory and actual measurement evidence; no adoption or implicit boot |
| Egress/ports | `MachineSpec::{allowed_hosts,ports,resources}`, `EmbeddedRuntime::set_egress_policy`, public `PortMapping` | Exact network backend/empty offline allowlists, approved publish configuration, durable ports and material identity |
| Startup workload | Public `MachineSpec::to_record` / `VmRecord` fields and SDK runtime startup | SmolBox reserves and commits creation itself; the SDK convenience creator inserts its own record and cannot be called after that reservation. Resolve opt-in inheritance before reservation, bind the resulting record and keep bounded startup/readiness qualification separate. |
| Existing image command context | `RunConfig::in_machine`, `workload::record_mounts_to_bindings`, `persistent_overlay_owner_with_lineage` | Receipt-checked record and observed running socket; preserve clone overlay lineage and runtime guest mount tags, not host paths |
| Buffered stdin | `AgentClient::{vm_exec,run_non_interactive}`, `RunConfig::with_stdin` | Finite protected worker, public UTF-8 limits, SDK reply allocation bounds and explicit dispatch/Exit classification |
| Background launch | `AgentClient::run_background` | Retained-image restriction, bounded launch observation and typed PID evidence; no final Exit or PID cleanup authority |
| Streaming commands/files | Existing SDK streaming and capped atomic transfer APIs | Preserve current collector/credit/leases and extend authenticated context to new source kinds |
| Terminal input/resize/output | `AgentClient::run_interactive_io`, public `InteractiveInput`/`InteractiveOutput` | Isolated owned session worker, bounded total input and SDK queues, finite poll/collection, native terminal connection adapter |
| Console logs | SDK manager's public `console_log` accessor; revision-specific console path under the enrolled domain | Do not construct an SDK manager merely to discover a path; bind a bounded reader to the verified machine/domain, retain missing-log uncertainty |
| Registry preparation/publication | `smolvm_registry::{pull,pull_with_progress,push}`, public `registry_client` and parsed `Reference` | Exact manifest/content identity, protected cache/output, finite request/byte budgets, credentials and destination/TLS/redirect policy |
| OCI image list/pull | `EmbeddedRuntime::{list_images,pull_image}` and public agent APIs | Existing-running-agent preflight; typed image identity, source eligibility and seeds disabled until separately accounted |
| Checkpoint capture/restore | `EmbeddedRuntime::{start_forkable_machine,checkpoint_machine,restore_checkpoint_machine}`, portable checkpoint APIs | Approved bare/offline eligibility, portable/CPU compatibility, material transitions, capture streaming/resources and authenticated restore intent |
| Stopped disk growth | `storage::expand_disk::<Storage/Overlay>`, public disk resolve/open APIs | Stopped/source proof, format/geometry checks, durable increased reservation, SDK record update and authorized material proof |
| Local volumes/mounts | Public SDK record/mount conversion; HTTP volume handler performs filesystem operations directly; public vm_uid_drop_active confirms the unprivileged VMM retains its account | Protected account-bound provision, bounded observations and descriptor-relative deletion exist with retained native authority and SDK mount exclusion. Explicit caller-fenced resolution resumes matching entered deletion or starts first cleanup of completed provisioning; no normal observation/startup replay or absence adoption. These are non-VM contracts, not guest qualification. Schema-2 staging records exact temporary inode before no-replacement public rename, with distinct final evidence and schema-1 read compatibility. Explicit fenced abort now cleans only matching protected temporary or published unready backing, with SDK mount exclusion for both paths and separate abort evidence. Typed protocol/helper action routing and immutable operator-root catalog selection now exist behind disabled volume admission. Caller mutation deadlines and bounded observation deadlines remain distinct. Exact volume limits and Linux-only/dependency negotiation now agree across Rust/Elixir and engine-constant checks. Elixir request/reply/store authority, unproved temporary cleanup, long/large-tree acceptance, exclusive mount creation/attachment, guest/replacement/mode qualification and public/store integration remain pending. |
| Export | Public pack asset collector, SDK `pack_export`/manifest seeding and registry push | Approved stopped source, exact container/bare preservation, bounded tool/auxiliary-VM policy, verified publication receipt |
| Branch/held release | Public `agent::fork::{prepare_fork,prepare_held_fork,activate_held_fork}`, `AgentManager::start_with_full_config` | Source/child identity, ordered gates, child boot enrollment, hold metadata, parent dependency and additional backing reservations |

## Findings that change the implementation

The pinned SDK convenience streaming collector stops at 11 MiB. The public
AgentClient send_raw/recv_raw APIs and official AgentRequest/AgentResponse types
permit explicit bounded streaming without that convenience cap. The engine now
uses those verified types in an unadvertised owned command worker, retaining SDK
frame limits and SmolBox's 16-MiB command bound. Public RunConfig/context APIs
still supply image user/mount/overlay selection. A normal non-VM peer verifies
large environment transmission, pre-Exit output and 12-MiB streaming; public
wire/descriptor/reader activation and ordinary guest qualification remain pending.

The runtime's `command_run_config` and `command_client` are private. There is no
need to copy them or patch their visibility: public `RunConfig::in_machine` and
`workload::record_mounts_to_bindings` supply overlay lineage and guest-side mount
bindings from an already authenticated record. `AgentClient::connect` opens the
already verified socket without an `EmbeddedRuntime` or an attach/boot helper.
The configuration witness proves regular and fork-lineage overlay selection and
read-only guest mount conversion, not live socket authority or command behavior.

`EmbeddedRuntime::resize_machine` reaches `agent::live_resize::grow_disks`, which
rejects anything other than `RecordState::Running`. It therefore cannot implement
the public managed stopped-growth contract. `storage::expand_disk` is callable
for both SDK disk types and delegates to the SDK disk algorithm. The later
engine implementation must inspect format/backing geometry and publish a
verified material transition; the compile witness does not resize any file.

The registry warm handler calls a private `pull_smolmachine` helper. Public
`smolvm-registry` pull/push APIs avoid copying HTTP routing/state while retaining
upstream artifact transport. They are asynchronous and may do cache/resume work;
the native preparation supervisor must preflight manifest size/digest, bound
staging/deadlines and preserve partial/unknown evidence. It must preserve the
HTTP explicit-token private/loopback restrictions rather than treating public
client construction as destination authorization.

The channel terminal API does not use the host tty but clears its socket read
timeout and can wait after EOF. Its receiver/pending writer queues need a bound
on total accepted input and an isolated finite worker lifetime. Closing the
input sender is not a worker collection proof and never a confirmed guest Exit.
The witness checks the public session and resize types only.

Image seeds can invoke a builder executable and retain extra cache/VM resources.
The initial implementation keeps `SMOLVM_IMAGE_SEEDS=0`; direct OCI pulling still
needs approved guest egress. A future enabled seed path requires separate owner
enrollment and resource/cache policy. No CLI builder is authorized by this audit.

`collect_from_vm_assets` may boot a temporary flattening VM. The earlier guard
refusal and private fixture conversion are documented historical evidence, not a
product export proof. Product export must explicitly approve/bound host conversion
or enroll/account the auxiliary VM. The compile witness is not executed.

`Engine::qualify_export_source` now produces an opaque, movable stopped-source
lease from existing creation/material authority. It holds the source gate, root
FD/domain and work allowance; repeated bounded record/dependency checks reject
changed, running, ambiguous or foreign sources. A replacement engine cannot
consume it. This is source admission, not disk conversion, manifest/registry
publication evidence or ordinary package qualification. Export workers must still
consume this lease, qualify disk/layer/asset descriptors and retain owned helper/
staging allowances through actual collection. Native assignment history and public
SDK descriptor approval still fence exports until those paths are implemented.

Bare source disks now have an engine-owned descriptor preparation and logical
streaming converter. It consumes the stopped-source lease, atomically promotes
the FD allowance, verifies both declared disk capacities and reads raw/QCOW v2/v3
bytes through bounded buffers. Allocated clusters, backing inheritance, explicit
zeros and backing EOF are distinct. Source/backing file versions and directory
identities remain bound before/after reads and final digest issuance. Conversion
streams to a coordinator-owned sink without booting a hidden SDK helper or
invoking a host CLI. Export treats raw disk contents as opaque; growth retains
its ext4 checks. Existing eight-backing, 64-GiB-per-disk and finite QCOW metadata
limits remain explicit, pending qualification of every required source shape.

This is disk preparation/conversion, not `.smolmachine` packing or registry
publication. It does not materialize/own a staging artifact: the future export
coordinator must reserve and retain whole-job staging before selecting its sink,
qualify runtime libraries/templates and preserve container semantics separately.
Public export capability and native history admission remain disabled.

Bare disk materialization now has protected export staging. `MaterializedExportDisks`
retains the source lease, writes sparse request-private raw files, independently
rehashes their descriptors and records exact file versions before readiness.
`export-stages-v1` indexes registered roots and immutable source/request/byte
allowances; it is created only by explicit export work. A separate aggregate
512-GiB logical scratch allowance survives handle retirement and is restored
conservatively on registry reopen. Live handles fence external cleanup; explicit
quiesced cleanup records intent, removes only the registered root and releases
bytes only after a synced completion. Recovery does not reopen a writer or adopt
existing output. Root mismatch/missing proof retains capacity, and uncertain
cleanup cannot attest pre-dispatch failure. These are ordinary file/model checks,
not live process-loss or persistence-interruption qualification.

Bare pack construction now consumes `MaterializedExportDisks` and qualified
operator asset grants. Qualification and its three retained asset descriptors run
inside the existing whole-job FD allowance. The grants require the exact platform
library/rootfs names, protected regular files, explicit size/digest approval and unchanged descriptor/
path versions. Qualification is byte/file authority, not a runtime bootability or
package approval claim. The package builder now creates a bounded reproducible
rootfs tar and includes it in the approved asset inventory. Preflight selects only
that declared tar and exact library entries, then the engine installs one catalog
bound to host package/domain/library root. Asset setup uses native admission and
opens no detached FD grant. Older packages without the tar omit the catalog.
`MaterializedExportDisks.pack` selects the installed catalog; requests cannot
supply host asset paths. Current artifact guest boot remains unqualified.

A single-thread tar/zstd writer uses public SDK manifest seeding/footer types,
fixed archive paths, a finite compression window and bounded reads/writes under
the original deadline. It avoids the SDK Packer's implicit cache permit/staging.
The manifest preserves source workload/env/user/secret references and allocations;
VM storage/overlay entries retain full logical bytes. The output includes SDK CRC
and whole-file SHA, independent descriptor rehash and a protected Packed record.
Fresh staging schema 2 adds Packing/Packed; schema-1 rows remain readable/cleanable
without writer resumption. Failed packing retains byte reservations for explicit
cleanup. A PackedExport retains source gates/domain/work capacity; it is private
scratch, not registry publication proof.

`PackedExport.publish` now makes one bounded publication attempt with SDK OCI
manifest/index types and a transient scoped push bearer. Unlike the convenience
SDK push path, it neither retries uploads/auth nor merges an existing tag index.
Both tags must be vacant. Fixed-size PATCHes validate exact progress, URL origins,
response sizes and final transmitted SHA before blob commit. Manifest, platform
tag and one-platform index acknowledgements precede a native completed receipt.
Source postconditions are rechecked before recording completion. Controller-side
registry verification still remains distinct from this acknowledgement.

Fresh private staging schema 3 adds prepared/entered/completed publication state,
with only digests and nonsecret destination identity in the ledger. Schema 1/2
rows remain readable and cleanable; previous staged artifacts cannot resume
publication. Bounded inspection returns only an exact protected completed receipt,
including after normal registry replacement. None proves neither absence nor
permission to replay. Failures retain host staging for explicit cleanup, and even
successful publication holds source/work/scratch until disposal. No registry
objects are deleted by native scratch cleanup. Container flattening, managed
controller routing/cleanup integration and ordinary
current platform/package/export-import/consumer qualification remain pending.
Public export admission stays disabled.

The gated protocol-2 export adapter now accepts path-free preflight, publication,
exact completion lookup and explicit quiesced staging cleanup. Operator setup
resolves at most 32 approved destinations, hashes bounded CA inputs and caches
the immutable engine destination. Reader admission compares only cached IDs,
destination hashes and finite byte allowances; it performs no trust-file or
registry I/O. The executing adapter requalifies the source and installed assets
under the original budget. Once materialization is attempted, failures retain
uncertain dispatch classification because private scratch may already exist.

Rust and Elixir validate the same synthetic publication/cleanup fixtures and
executing engine limits. Zero-output terminal replies bind source, operation,
original request fingerprint, destination, tag, artifact size and package
architecture. Publication lookup grants no absence or replay authority; cleanup
has a distinct proof shape. Scoped push tokens are removed from retained call/
session bookkeeping. Lookup and cleanup retain reserved control admission with
work lanes occupied, without needing a current destination catalog. These are
wire/adapter contracts, not live package qualification.

Native durable export history now freezes the current enrolled material receipt
at acceptance and an exact bounded request before dispatch. Public receipt shape
retains an optional internal typed acknowledgement; source/request/destination/
platform and independent config/content verification must agree. Separate cleanup
authority is required for completed/resolved-unknown release. Source observations,
stopped state and registry acknowledgement cannot supply that proof. Permanent
tag claims survive every outcome. Selective codec v28 and the separate
native_export_histories reader preserve earlier HTTP/native envelope semantics,
including rejection of smuggled nil defaults. Runtime startup keeps interrupted
export unknown without importing native journal evidence or replaying work.
Memory/PostgreSQL guarded store contracts and a deterministic normal startup peer
exercise this foundation. Scoped managed preflight/publication now retain the
pinned helper, use cached destination metadata without reader I/O and freeze
source-sized staging plus artifact allowance before dispatch. Exact protected
acknowledgement lookup precedes the existing independent registry verifier.
Explicit controller resolution serializes with reconciliation, quiesces the
pinned bridge and consumes cleanup before disposition observation and guarded
release. Changed intent or expired shared control budget cannot commit release.
Typed reply/control and Memory-backed public resolution models establish those
controller boundaries. No-stage cleanup now requires an authenticated source
marker/current material journal, positive caller quiescence and the shared source
gate. It rejects unindexed roots and crossed recorded intent, then synchronizes a
schema-4 zero-byte retirement in a distinct proof domain. Exact protected cache
lag can recover that retirement; no writer or publication is recovered. Reopen
retains the fence without staging allowance. Full work/FD/metadata admission and
quarantine do not consume its existing separate 32-MiB material-control allowance.
Rust/Elixir limits and the bridge's executing-constant checks negotiate this bound.

Registered export scratch already supplies its own protected root/source/intent
authority after VM-row removal. It neither adopts nor disposes a source VM and
does not require a second source-deletion enrollment. A private removed-source
model exercises exact cleanup and rejects minting an unrelated unstaged receipt.
An already deleted source lacking stage/retirement authority still cannot enroll
itself from absence. A separate bounded `admit_export` action now enrolls protected schema-5 frozen
source/request identity before managed dispatch. Qualification remains read-only.
Dormant admissions reserve no scratch bytes; materialization records Entering
and retains the byte ceiling before directory creation. Cleanup after source
removal retires only exact registered authority. Entering with an unproved
directory preserves it and the allowance rather than adopting a writer.
Container export and ordinary exact-package acceptance remain pending. Public exports remain
disabled; these models do not qualify native production of every witness.

SDK deletion independently derives storage from its process cache root. The
engine now rejects a mismatch with its bound VM path before deletion enrollment
or SDK entry. A DB-only fixture cannot exercise that lifecycle call safely;
its source-removal contract uses only the fixture's own row and directory.
Ordinary SDK deletion still requires a correctly scoped helper/process run.




The runtime convenience fork APIs always release the inherited forkpoint and
offer no held-slot option. Public launch-agnostic `prepare_held_fork` and manager
`start_with_full_config` provide the preparation and guarded subprocess-boot
building blocks; both now have compile-only witnesses. The controller must verify
identity reset before reporting a usable child, leave a held child parked and
apply `activate_held_fork` only for the correlated durable release intent. Do not
use a normal convenience fork to simulate hold after the child was released.

Public fork APIs snapshot/clone and then boot the child. Existing immutable boot
context alone does not enroll an arbitrary child or authorize copied source
labels. The controller must create the child intent, authorize/enroll its exact
name/material, and mint independent proof only after correlated supported state.
Held activation must preserve the durable release intent and version identity.

## Current evidence and remaining gates

The macOS compile-only fixture and its three pure configuration tests pass.
Nine selected Elixir tests pass, including four new parity coverage checks and
the existing backend contract tests. Both full SDK inventory checks pass.
Private compiler logs remain in `.local/http-parity/`; upstream compiler warnings
are unchanged. No helper, VM, registry request or fault campaign ran.

This establishes callable clean-source building blocks and checked scope. It
does not complete P1–P9, approve a changed native package, prove runtime bounds,
or qualify Linux/macOS feature behavior. The remaining gates above belong to
their implementation phases; all parity acceptance/evidence is explicitly pending.
If implementation discovers a boundary that cannot meet the contract, record the
exact blocker and evaluate clean APIs/an official SDK upgrade without patches.
Crash validation remains deferred and distribution approval remains separate.


## Stopped growth geometry boundary

The pinned SDK `expand_disk` enlarges raw backing bytes or the QCOW2 header's
virtual size; it does not run host resize2fs or immediately enlarge ext4. Guest
normal boot performs filesystem growth. Engine stopped growth now captures both
disks through stable descriptors before journal entry, verifies record-size
correlation, and checks exact requested backing/virtual capacities plus preserved
raw filesystem or QCOW header/backing-reference evidence before updating the SDK
record or committing material proof. Physical QCOW file length is not capacity.

Pure sparse-file models call the unmodified public SDK grow API and cover raw and
QCOW2 versions 2/3, unchanged targets, padding, replaced/shared/redirected paths,
changed ext4 UUID/superblock, malformed counts and unsupported QCOW metadata.
The parent now dispatches mutation through the existing authenticated owned job
worker. Protected bounded metadata carries original descriptor/parent/layout
witnesses and exact targets; the worker reopens both originals before any SDK
call, without a runtime, database writer, agent or boot. Distinct correlated Grown
proof, exact normal child collection and parent geometry checks precede database
and material completion. Growth retirement uses no signals: unresolved children
retain machine/source/domain/geometry/job leases in the collector and quarantine
admission. No lost result is replayed.

Selected ordinary rebuilt-helper checks grow sparse raw/QCOW fixtures and reject
a substituted companion before mutation. An engine fixture verifies private
record updates, immutable creation authority, correlated journal observation,
pre-dispatch cancellation and duplicate-operation rejection. These are non-VM
filesystem/model checks, not product/platform qualification. Full QCOW backing-
chain/filesystem verification, public durable increased reservations/histories,
wire activation and ordinary platform witnesses remain pending. Growth is not
advertised.

## Completed growth transition contract

Shared-engine GrowthTransition/GrowthChange are transport-independent typed
results for completed growth. They bind the complete prior/next receipt,
operation ID, exact GrowDisks request, old/target capacities and immutable SDK
configuration hash. Canonical request and chained material digests retain the
existing journal schema and Rust serde field order. Null omitted targets differ
from explicitly repeated target values. Shared synthetic Rust/Elixir fixtures
verify the same bytes; they contain no real enrolled receipt or collected proof.

Engine.expand_disks_transition_owned performs the existing owned growth and
then reads its correlated completed journal evidence. Its read-only observer
shares the exact machine gate and verifies domain/database/marker identity; it
cannot return proof for an entered-only operation, foreign ID/request or another
prior receipt. Journal validation also preserves one immutable configuration
hash across growth history and pending entries. Elixir GrowthTransition validates
root and linked proofs, intent binding and at most 32 ordered history entries
without treating digests as signatures or inventing inventory authority.

The ordinary synthetic-database engine fixture now exercises the returned
transition and correlated observation after actual sparse-file SDK growth.
Public wire activation, durable expansion history/current-receipt integration,
reader-first codec evolution, operator resolution and full format/platform
qualification remain pending. This contract does not enable disk_growth.

## Growth wire and Runtime dispatch foundation

Protocol-2 ExpandDisks and InspectGrowth carry the exact preceding receipt,
persisted expansion ID, nullable original request and previous sizes. Grown is
separate from GrowthPresence: neither a bare observation nor missing journal
proof can stand in for correlated SDK completion. Rust and Elixir validate the
existing canonical transition fixture, root/request/chain hashes and exact stopped
post-capacity. Missing nullable fields, shrink/no-op/out-of-range requests,
foreign identity/ID, stream bytes, reused replies and mismatched geometry reject.

The Port adapter converts engine evidence without changing it, uses an absolute
deadline captured before pre-inspection and performs the existing owned bounded
SDK growth. The resulting receipt authorizes a stopped observation; a concurrent
state change yields may-have-dispatched uncertainty. Journal proof lookup shares
bounded observation admission and cancellation/deadline checks. It does not
mutate, reconcile, initialize a runtime or supply absence/cleanup authority.

Runtime pre-inspection and dispatch use the retained record's scoped reference.
A native received proof is validated against persisted intent. A local pure
expansion preview selects the new receipt for follow-up inspection; durable
intent is still dispatching until the real observation is committed. HTTP retains
its existing response-then-observe behavior. The backend operation inventory now
marks expansion implementation present while every parity acceptance remains
pending. The shipping SDK descriptor still excludes disk_growth and library
approval rejects a requested future growth descriptor. Wire capability support
alone does not enable public admission or qualify a platform/package.

Unresolved growth observations now query completed journal evidence through the
existing InspectGrowth path before inspecting the current receipt. The local
promotion binds the full original durable request, prior receipt/sizes and targets;
both reads share one absolute deadline and captured owner/epoch. Missing evidence
keeps the old reference; its geometry cannot satisfy explicit target/proof
resolution, and only separate receipt-bound absence can support deletion. Startup
checks the committed current geometry rather than the original disk sizes, and
records active expansion as unknown without adopting completed proof or reducing
reservation. Entered-only repair and format/platform qualification remain pending.

## Bounded QCOW allocation-table preservation

The scanner follows the QCOW2 header and pointer definitions in the
[QEMU format reference](https://www.qemu.org/docs/master/interop/qcow2.html).
The clean SDK's resize changes only the virtual-size field; parent and worker
witnesses now require stable host length and all selected allocation metadata.
Fixed-buffer scans authenticate header extensions/backing text, L1/L2 tables and
refcount table/blocks with position-bound hashes. Range/flag validation prevents
out-of-file, misaligned and metadata-aliased data pointers. A 64-MiB per-disk-scan read ceiling,
4,096 extents and separate reserved scanner memory bound the operation. Geometry
reads occur after job admission and share its lease with eventual dispatch.

Backing-chain content/identity, semantic refcounts and virtual ext4 mapping still
require implementation and qualification. Compressed-entry and format coverage
remain explicit gates; structural table preservation cannot replace those proofs.
No new SDK descriptor or public capability is enabled by this change.

## Backing-chain and mapped filesystem witness

The engine now binds up to eight backing files as flat path/parent/file-version/
capacity/layout witnesses. It rejects cycles, missing/redirected/substituted files
and unsafe parent modes, without retaining a descriptor per layer. Declared raw/
QCOW formats must match the selected image. One shared 64-MiB allocation-table
budget covers the chain, and failed scans retain their spent credit. The existing
16-KiB protected worker envelope bounds serialized witnesses before SDK entry.

Virtual superblock reads follow standard L1/L2 mapping, unallocated backing
fallback and explicit-zero suppression from the
[QEMU format](https://www.qemu.org/docs/master/interop/qcow2.html). Filesystem
capacity validation uses the ext4 block-count/size/magic fields documented in the
[Linux superblock reference](https://www.kernel.org/doc/html/latest/filesystems/ext4/super.html).
The resulting bytes/hash and capacity are preservation evidence during stopped
resize, not immediate guest filesystem growth, filesystem fsck or a whole-file
backing-content hash. Semantic refcounts, source provenance/content qualification,
remaining format/guest/platform coverage and entered-only repair remain gates.
This change does not activate disk_growth or modify the verified SDK.

## Semantic standard-format refcounts

The engine now checks the 16-bit two-level counts described in the
[QEMU host-cluster reference](https://www.qemu.org/docs/master/interop/qcow2.html#host-cluster-management).
Expected counts include selected metadata spans and standard allocated/preallocated
data references. Actual blocks use their original table indexes; missing coverage,
leaks, count mismatches and copied flags on shared data reject before SDK entry.
No repair or replay is implicit. The second L2 pass consumes shared IO credit and
an 8-MiB expected-count cap is charged up front to the owned job. Virtual 1–64-GiB
eligibility remains distinct from physical-footprint admission.

These checks cover the selected standard layout with disjoint metadata and the
existing no-snapshot/no-compression policy. Broader format/source provenance,
ordinary guest/package/platform acceptance and entered-only repair remain pending;
structural/semantic models do not qualify a public growth descriptor.

## Entered-only explicit qualification foundation

Pending growth now contains the original protected geometry witness. Explicit
Engine.qualify_growth requires quiesced=true, the exact entered intent, ownership,
stopped SDK metadata and complete preserved target geometry before committing an
engine material proof. It never repairs disk bytes or SDK rows itself, boots a VM,
sends signals or replays resize. Retained source/machine leases and quarantine
remain fences. A separate qualification digest preserves the distinction from a
correlated SDK completion; public store resolution must remain resolved/unknown
as appropriate. Legacy missing witnesses are readable but cannot be invented from
inventory. Existing canonical transition hashes and omitted-field bytes survive.

The bounded no-child operation reserves journal/scanner metadata while control
observations remain admissible. Explicit wire/adapter/Runtime resolution, compatible
replacement-reader and ordinary platform/package/consumer qualification remain
pending. No public growth descriptor is enabled by this foundation.

The explicit qualification foundation is now connected through distinct protocol-2
QualifyGrowth/GrowthQualified messages and native-only Backend.qualify_growth.
Engine prior-size validation precedes journal publication. Public stopped resolution
pins/quiesces/claims its native owner, qualifies saved repaired geometry, validates
an uncommitted resolved preview and inspects the new receipt under one budget.
Read-only inspection and deleted absence resolution do not dispatch qualification.
Crossed result kinds and missing/false quiescence reject; work quarantine remains
fenced. Public descriptor activation and ordinary exact-package acceptance remain
pending, with crash validation deferred.


## Passive existing-machine image listing

The HTTP images handler returns an empty inventory when its VMM is not alive.
Clean SDK EmbeddedRuntime.list_images calls started_handle and may boot; this
convenience API is unsuitable for passive listing. The engine now verifies saved
receipt/record/process identity and uses an owned bounded worker only for an
existing running agent. It sends one public AgentRequest::ListImages and receives
one AgentResponse through AgentClient send_raw/recv_raw; it never retries or starts.

The image response relay admits at most 2 MiB before body allocation, directly
projects at most 1024 image entries and discards unrelated guest fields with
serde's ignored-field reader. A plain response struct avoids tagged-content
buffering. Only six validated public fields survive; SDK normalization supplies
empty unused fields for its typed parser. Packed digest observations remain packed
and neither configuration digests nor references become approved source identity.
The private spool is capped at 8 MiB, the job reserves one work slot/child,
20 descriptors and the 32-MiB metadata pool, and successful exact child collection
is required before publication. All ownership/job leases survive uncertainty.

Non-VM peers prove valid/invalid response handling and ordinary child collection;
a stopped-engine model proves no socket/worker/database mutation. Protocol-2 ListImages/Images and Elixir request/channel/reply translation now carry
bounded JSON through credited file events with exact count/byte completion.
Public feature activation and exact-package/platform acceptance are pending.
This foundation does not qualify OCI source creation or managed image pulls.


### Image inventory bridge and forwarding

ListImages requires a protocol-2 receipt, images: 1 and job_resources: 1, with a
30-second total budget. Images completion carries bounded count/byte totals;
the array travels in at most 64-KiB file events rather than a large result frame.
The session rejects crossed inventory kinds, other streams and mismatched totals.
The shared engine keeps its collected worker/job/spool/domain/source/machine leases
through credited forwarding, including callback failure. Stopped empty replies
use the same JSON/count representation without creating a worker.

Elixir returns the existing ImageInventory/Image types, validates the exact saved
receipt and image projection and maps errors to the HTTP :images vocabulary.
Packed/configuration-digest observations and empty_or_unavailable remain unchanged.
Listing uses the work lane and cannot enter after quarantine as an observation.
The protocol's bounded capability inventory grows to 32 entries for the planned
25-capability combination (current plus growth and image listing); current and
legacy descriptors keep their original lists. The Python qualification selector
uses the same conditional capability order. images remains absent from the
implemented/approved descriptor and package policy until full image workflows
and applicable acceptance gates pass. No approvals transfer to changed bytes.


## Existing-agent OCI pull worker foundation

Clean AgentClient.pull with use_registry_config(true) can load account settings,
resolve host Docker credentials (including credential helpers), rewrite registry
mirrors and replace its read timeout with the SDK pull default. Calling this
convenience method would not preserve explicit native inputs, no-CLI behavior or
SmolBox's whole-operation deadline. The private worker therefore uses the public
AgentRequest::Pull and AgentClient send_raw/recv_raw APIs with the exact validated
reference/platform and one absolute deadline. This initial worker supplies no
authentication/proxy override and reads no registry/Docker configuration. Approved
native credential handling remains a required separate integration; this does not
qualify private-registry authentication or silently narrow the final parity scope.

The protected 4-KiB metadata file binds schema/request/deadline and must match the
controller's separate expected intent. Digest-pinned reference validation matches
Source's public host/port/repository grammar. The relay admits each reply header
before allocation (2 MiB), caps aggregate IO at 64 MiB and progress at 4096 frames,
discards progress/error diagnostics and unused metadata without constructing their
nested JSON values, and delivers only one projected final image. It sends no
progress strings to the native bridge or public caller. The final configuration
digest/reference/platform must match the exact requested image; packed synthetic
metadata cannot complete a pull. A manifest digest is not confused with the
observed configuration digest.

Private ImagePulled evidence is distinct from list/file/command completion and is
accepted only for the matching typed pull request. Job accounting reserves one
work slot/child, 21 descriptors, bounded staging and the full 32-MiB metadata pool,
leaving both reserved control slots available. The supervisor requires correlated
evidence plus exact successful child collection; uncertainty keeps its ordinary
retained leases/quarantine behavior and never authorizes guest termination/replay.

The production engine now consumes the parent factory and extracted result under
receipt-bound direct OCI/network/running preflight, one reserved job and one
deadline. Exact operator source catalog selection, credential handling where
applicable and Port/managed command-slot/durable unknown integration remain
pending. No wire capability, implemented
SDK descriptor, native package policy or public admission is enabled here. The
ordinary non-VM peer observes exact request bytes and normal collection for valid,
packed, changed-reference and error replies, without initializing a runtime or
SDK database. These tests do not qualify a guest pull or an OCI-created machine.


## Verified direct OCI creation authority

VerifiedOci is constructed from at most 1-MiB platform-manifest and 1-MiB config
bytes. The requested SHA-256 reference must match the manifest's raw bytes, the
configuration descriptor must match exact config size/content, and Linux/config
architecture must match the selected platform. OCI/Docker platform manifests are
supported; index media types reject. Layer descriptors are counted/validated
without retaining their vectors. Known duplicate fields reject through typed
serde decoding. Verification performs no registry/network/SDK action and is not
operator approval. Create admission additionally requires the native guest
platform and existing CreationFeatures workload/network validation.

The shared engine can create direct OCI disks/records under fresh SDK reservation,
work/descriptor/metadata admission, the per-name gate and one deadline. It uses
public SDK MachineSpec.to_record, disk manager/format APIs and commit_reserved_vm;
there is no runtime creation, VM start, pack import or image seed builder in this
operation. The same private marker/material root publication path now serves pack
and OCI records. Template verification remains before SDK formatting, preserving
pack creation behavior. Failure after SDK reservation is uncertain; releasing
SDK serialization does not release durable capacity or authorize replay.

The immutable SDK record hash already includes image and source_smolmachine.
Direct OCI has the exact digest-pinned image and no imported pack field; local,
registry and checkpoint packs retain source_smolmachine. Receipt/journal validation
checks these fields rather than inferring origin from image inventory or labels.
Engine.qualify_image_pull requires a versioned saved receipt, direct OCI origin,
explicit validated network policy and matching native platform. It does not grant
source approval, running evidence, command-slot ownership or quiescence.
Existing receipt/material/codec bytes are unchanged.

Public Port direct OCI first-start remains disabled and explicitly rejects before the
SDK convenience path, whose image bootstrap may read host registry settings or
extend pull timeouts. Source catalogs, host metadata/credential preparation,
wire/assignment persistence, owned bounded bootstrap and platform qualification
remain pending before remote_sources/images can be approved. Model tests publish
fresh private SDK records/root receipts without creating or booting a guest;
ordinary non-VM helper evidence is not live OCI qualification.


### Receipt-bound engine pull dispatch

Engine.pull_image_owned dispatches only to an already-running direct OCI origin.
The enclosing bridge must select the exact approved source and own the durable
command slot. The engine verifies a versioned receipt, private marker/journal,
immutable OCI-versus-pack origin, explicit network policy and strict saved process
identity. It reserves the pull's work/child/FD/staging/metadata demand before SDK
record IO and transfers that same lease to protected worker preparation. It never
creates another runtime, boots, consults settings or replays a pull.

Only exact successful child collection plus matching ImagePulled evidence can
return an ImageObservation. The engine rechecks the original receipt, source/
network fields and saved process identity under the remaining absolute budget.
All machine/source/domain/job/spool leases stay held through this final check.
Retained collection and failed/missing/late evidence remain uncertain; a collected
helper is not proof of guest quiescence after an unconfirmed pull. No SDK creation
metadata or receipt is updated. Public feature/capability activation stays pending.

The shared SDK compatibility reader now retrieves only the selected receipt name
with the existing read-only transaction, schema/inode checks, SQLite progress
cancellation and an 8-MiB returned-blob cap. Image inventory and pull preflight use
this path; malformed unrelated JSON cannot become ownership or block the selected
row. Oversized payloads and a row's mismatched embedded name reject. Pure private
SDK models cover this behavior and cancelled/stopped pull rejection without
staging, process spawn, guest entry or record mutation. Resource models prove one
reservation survives protected preparation while both control slots remain usable.


## Pull protocol and exact helper source admission

Protocol-2 PullImage carries a saved receipt and credential-free exact OCI
reference/platform pair. Distinct Pulled completion carries only the six public
image fields and must match reference/platform/Linux configuration-digest intent.
The operation accepts no output stream; list/file/command evidence cannot satisfy
it. Request/response major, budget, strict fields and source/image byte/count
constraints are checked independently. Packed metadata is never pull completion.

The helper configuration adds optional approved_oci_sources (at most 32 exact,
unique reference/platform pairs). Omission preserves old serialized config bytes;
empty/absent/changed approval rejects PullImage before native entry. Catalog load
uses both wire constraints and the engine's complete Source-compatible grammar,
rejecting tags, schemes, credentials, invalid hosts/ports and auth/proxy fields.
Runtime selection binds the exact pair before scheduling. Operator catalog input
cannot enable a capability missing from the approved Hello/package descriptor.

Elixir has matching Request/Protocol/Channel/EmbeddedReply translation and the
existing Image result/error vocabulary. Scoped operation building additionally
requires the exact approved Source/ImagePull intent, an OCI-created retained
machine and an explicit network profile, with one constrained execution budget.
The owner checks source catalog membership independently, and helper config emits
only deduplicated OCI pairs for images descriptors. Neither SDK nor Elixir image
metadata grants source approval or rewrites the creation source. Rust/Elixir/Python
capability order agrees on list_images then pull_image; the planned combination
with growth now has 26 capabilities under the bounded 32-entry limit. Current and
legacy descriptor lists remain unchanged; images is still unapproved.

Pure session/channel/decoder peers cover exact catalog admission, schema/version
checks, crossed kinds/receipts/intent, rejected streams and packed/wrong-platform/
reference evidence. The helper bridge invokes a deterministic Native peer only
for exact approved intent and shuts down normally; no VM, SDK database or local
HTTP server is started. Source assignment/store/reader integration, credential
preparation, owned OCI bootstrap and ordinary exact-package/guest/platform
acceptance remain required. No P4/P9 completion or distribution approval is claimed.


## Bounded agent-side OCI bootstrap

The SDK convenience workload path pulls with host registry settings and can retry
a missing image or change the observation timeout. The new bootstrap worker uses
only public typed AgentRequest/AgentClient APIs: one exact digest-pinned pull,
followed by one detached Run when the receipt-bound record has nonempty argv.
An empty argv performs image preparation only. Environment, inherited user,
workdir, mounts and persistent overlay lineage come from the validated record.

A protected metadata blob is capped at 8 MiB and hashed with the full launch
intent and absolute monotonic deadline. The existing job lease reserves work,
worker-child, FD, staging and metadata budgets through collection. Pull retains
its existing frame/progress/aggregate caps. Detached launch admits at most
64-KiB raw frames, 8-MiB aggregate replies, 4096 progress frames and 16-KiB
combined output before forwarding a normalized SDK response. Progress and stderr
are discarded; container acknowledgment is distinct from guest Exit/readiness.
Only matching Bootstrapped evidence plus successful exact-child collection can
complete this worker. No retry, runtime owner, VM launch or SDK mutation occurs
in the worker.

Pure contracts bind launch fields, plan hashes, bounds and evidence kinds. An
ordinary rebuilt-helper peer verifies pull-then-launch, empty argv, launch error,
private diagnostic removal and normal collection without VM entry. This is
agent-side evidence only. The owned engine startup section below adds VMM
launch/enrollment and retained manager/controller integration. Credentials and
ordinary live platform/public-package qualification remain pending. Engine.start still rejects
direct OCI before the unbounded SDK convenience path. No images/remote_sources
capability is activated and no full parity acceptance row is closed.


## Owned direct-OCI engine startup

Engine.start_oci_owned now connects low-level SDK VMM launch with the bounded
bootstrap worker. It verifies the saved receipt, stopped state, exact direct-OCI
origin, explicit network policy, package templates and boot owner context before
entry. Pending portable restore inputs and unsupported auxiliary/source/credential
behaviors reject. LaunchFeatures carries the exact stored DNS filter and enabled
parent watchdog, without allow_image_pull_egress, packed-layer lookup or settings.
VmRecord public resource/port methods supply the remaining launch configuration.

AgentManager.start_with_full_config runs on an owned thread inside the helper
process, preserving the boot guard's exact parent requirement. One reservation
covers sequential VMM launch/bootstrap: one work slot, two children, 24 FDs,
32-MiB metadata and one byte of result staging, leaving eight control FDs. The
actual manager is retained by Engine; observational SDK reconnects cannot replace
its lifetime authority. Explicit stop uses that manager and source serialization,
then clears only confirmed stopped ownership. Busy managers prevent stopped/
missing observations from inferring absence.

The existing boot dispatch enrolls the VMM before SDK return and binds its PID.
Public SmolvmDb.update_vm records the actual PID/birth/state; the SDK's internal
mark_running/mark_stopped helpers are in a private module and are not called.
Only collected bootstrap proof and post-validation of receipt/marker/journal and
exact live process can return startup completion. No application readiness or
workload Exit is inferred. Cancellation/deadline returns uncertainty, fences new
work and retains the executing thread's leases until it actually returns. A late
SDK boot may record its actual launch identity but cannot begin bootstrap or
produce late success. No forced termination is used by this controller.

Four deterministic checks cover exact launch policy/unsupported features, normal
thread collection, pre-entry cancellation and a held non-VM call that retains
resources after explicit cancellation while both control slots remain available.
An engine preflight fixture proves cancelled/unconfigured startup leaves rows,
handles and staging unchanged. These do not exercise actual OCI VMM startup.
Public Port source assignment/start routing, credentials, ordinary live
start/stop/restart, current package consumers and full resource/platform acceptance
remain pending. Engine.start still rejects direct OCI on the current Port route;
optional image/source capabilities remain unapproved.


## Typed source authority on the Elixir/store boundary

Native structural validation now distinguishes a saved OCI Source artifact
identity from the local pack Artifact used by existing wire requests. Exact
alias/reference/manifest-digest/architecture equality is required across the
assignment and managed specification. A matching hash alone cannot turn a local
pack assignment into OCI origin. Retained image pulls inherit the original OCI
assignment and reserve no additional machine resources; their requested image
may differ without changing creation authority.

These combinations use selective native codec v19. Native v16-v18 and HTTP
envelopes retain their formats and reject relabelled source payloads. Memory and
the PostgreSQL example advertise native_sources: 1 reader support. Future source/
image descriptors additionally require the existing registry_sources/managed_images
atomic markers before enrollment. Deterministic Memory rollback/recovery and
fresh-BEAM reader tests cover this boundary; PostgreSQL evidence is compilation
only. No native SDK code or source inventory is modified by this unit.

This is durable intent, not a prepared artifact or accepted native request.
Public Assignment.new still rejects remote sources, current Request rejects
source creation dispatch and package feature approval remains disabled. Native
source wire/catalog/preparation integration, actual engine startup routing and
ordinary live platform/public-consumer evidence remain pending.


## Bounded host OCI manifest/config preparation

The clean SDK RegistryClient buffers manifests up to 32 MiB and blobs up to
64 MiB. Several non-success paths call Response.text without a byte cap, and
its client policy/whole-operation deadline cannot be replaced through public
construction. Those calls cannot meet this metadata path's 1-MiB documents,
error-body discard, destination and absolute-deadline contract. They are not used
for native OCI metadata preparation. The shared engine instead owns bounded
OCI Distribution reads using the already locked reqwest/Tokio dependencies,
the clean SDK's public Reference parser and the existing verified metadata API.
No SDK source/dependency versions are changed.

Engine.prepare_oci_metadata verifies the source grammar, domain and available
work admission before entry. Its owned job reserves one work slot, 12 descriptors
and 32-MiB metadata, with no child process or staging/cache mutation. A current-
thread runtime has one blocking resolver slot; if resolver completion is delayed,
caller observation can expire while that owned job retains its leases/domain.
Cancellation and one absolute deadline span all registry/token reads, followed
by domain revalidation. The caller's bridge must select the approved source first.

The request preserves repository and pinned digest, with only exact Docker Hub/
smolmachines infrastructure endpoint aliases. HTTPS is required except explicit
localhost/IPv4 loopback origins. Proxies, redirects and automatic decompression
are disabled. Successful bodies are admitted by declared length and actual
chunks; manifest/config are capped at 1 MiB each, and config additionally uses
its verified declared size. Errors are discarded before body allocation. The
manifest pin/schema/media/config descriptor is verified before any blob request;
config bytes/digest/size/architecture are checked before returning VerifiedOci.
Indexes cannot select another platform manifest.

Anonymous Bearer challenges have an 8-KiB cap, exact pull-only repository scope
and bounded parameters. Same-origin token services and the exact HTTPS Docker
auth origin are supported; credentials, alternate realms/ports/query/fragment,
changed scopes and duplicate challenges reject. A 64-KiB token response and
16-KiB ephemeral bearer are bounded and never become logs, environment, argv or
durable state. One identical authenticated GET retry is allowed; no global token
cache, account settings, Docker credentials, mirror lookup or mutation replay.

Eight new Rust checks cover endpoints/challenges, ordinary owned loopback registry
fixtures (not a smolvm API server), header/body admission, token flow, no redirect
or extra config request after failed manifest verification, cancellation/deadline,
pre-blob descriptor verification and actual engine record/handle/staging isolation.
These are non-VM evidence. Other approved token-service/redirect combinations,
private credential resolution, registry pack preparation/cache, public source
wire/catalog/start integration and ordinary current package/platform/consumer
qualification remain pending. No feature or full parity row is enabled.


## OCI source wire and managed translation

Protocol-2 now carries strict OciIdentity/OciCreate values through CreateOci,
QualifyOciCreation, InspectOciCreation and StartOci. They reuse the existing
create/qualification/creation-presence/start capabilities and outcomes without
changing legacy local Create shapes or capability counts. Source identity binds
exact kind/alias/manifest digest/reference/architecture; labels remain empty.
Mixed local/source authority, invented metadata/credential fields, malformed
references, legacy startup receipts and explicit null feature payloads reject.
The existing compact workload codec supports these creation/qualification shapes.

Session admission additionally requires protocol 2 and remote_sources approval;
the descriptor requires existing job_resources/buffered_exec/compact_creation
contracts. The native owner independently checks the exact approved OCI
reference/platform before engine entry. Source operations have no output stream;
created completion binds the original domain/name/token/incarnation/material
authority, and cannot be replaced by inventory or absence evidence.

The adapter connects approved creation to bounded metadata preparation and fresh
Engine.create_oci under one remaining deadline. Qualification validates source/
resources/user/features without creating a machine. Source-intent absence uses
read-only database/material checks without registry access, asset preparation or
handle acquisition. It has a reserved observation path. Startup verifies the
approved original source against receipt-bound creation metadata after admission,
then enters the retained-manager owned bootstrap path; a later image pull cannot
replace that origin.

Elixir request/compact payload/owner/channel/reply translation agrees. Feature-
gated catalog selection, source-only configuration, assignment qualification and
construction, managed MachineSpec translation and source-specific lifecycle
requests now exist. Native and Elixir catalog checks remain independent. Current
package policy and SDKIdentity implemented descriptors still omit remote_sources/
images: catalogs/readers alone cannot enable these paths.

Deterministic bridge/catalog, protocol correlation/version/compact, source-origin
startup rejection and nonmutating engine absence checks pass. These are not live
OCI platform/public-consumer qualification. Remaining private credentials/auth
combinations, registry pack/cache paths, platform/source/resource acceptance and
exact-package approval remain pending before public source activation.

### Mounted OCI launch and bootstrap phase boundary

Unmodified SDK AgentManager::start_with_full_config delegates to subprocess launch;
finalize_launch waits for agent readiness before returning success. The engine's
mounted OCI path keeps root/backing descriptors and exact saved/current proof
through that call. It promotes its existing mount lease to the same 24 work-FD,
two-child, bounded-staging and 32-MiB metadata demand used by OCI launch/bootstrap.
It does not acquire another work lease or increase the global 32-FD declaration
and eight-FD control headroom.

Mounted bootstrap retains a bounded in-memory plan without opening spools or
spawning its worker during VMM launch. Only after SDK readiness does it close
parent root/backing descriptors, while carrying volume gates, domain guard and
full proof into the supervisor's retained lease box. Bootstrap spools and worker
then use that reserved job. Collected results retain the job and gates through
final record/material/actual-mount verification; unresolved collection retains
them in the supervisor. Unmounted OCI preserves its earlier spool preparation.
Guest bootstrap uses SDK runtime mount tags and read-only mode, never host paths.

Non-VM admission, handoff, pending-plan, wire dispatch and guest-binding contracts
cover these boundaries. They are not measurements of live Linux FD peaks, guest
mount readiness, replacement-write behavior or changed-package qualification.
Those ordinary checks remain pending before volume/source capability activation.
Crash qualification stays deferred and SDK source remains unmodified.

### Retained mounted commands

Buffered, owned streaming and background command entry points now accept current
operator volume policy. They qualify journal-bound mount proof before the machine
gate, preserving volume/machine gate order, and recheck full proof plus confirmed
running state before worker dispatch. No command starts a stopped machine or
selects a host path from its guest arguments. Unqualified mounted command calls
reject before SDK entry; the legacy direct streaming entry uses the owned worker
when an approved mounted machine is selected.

The retained mount lease promotes atomically to one worker child and exact bounded
output staging while retaining the whole work metadata/FD allowance. Parent
backing descriptors close before worker spool/pipe preparation; volume gates,
domain and full proof stay in the supervisor's lease box through collection or
uncertain retained work. Guest image context continues using SDK runtime mount
tags and read-only flags. Port's policy-aware path forwards the original credited
output callback. Terminal integration and ordinary Linux guest/resource
qualification remain pending; no volume capability is activated by these models.

### Checkpoint restore ownership boundary

Unmodified portable_checkpoint::restore_from_path_at validates compatibility, then
selects its own SDK reservation token, constructs an internal restored record,
commits it and removes partial VM storage on error. Calling it beneath an already
reserved SmolBox create would conflict with the reservation; observing its record
cannot supply lost SmolBox authority. The selected integration uses public
materialize_for_restore, install and discard_transport_pack under fresh SmolBox
reservation and neutral bare record construction, rather than copying the private
restored_record function or adopting SDK inventory. Owned installation/start and
uncertainty handling are still pending.

The shared approval type now checks current exact SDK and host/guest platform,
captured allocations, basic idle bare topology and forbidden workload, packed-layer,
credential and network dependencies. It represents classic and chunked SDK
checkpoint header versions and delegates actual CPU/hypervisor compatibility to
the SDK. Checkpoint artifact allowance is separately bounded at the public capture
policy's 64 GiB; ordinary pack/command/file caps stay unchanged. Header eligibility
is not byte integrity, captured-process attestation, ownership or a successful
restore. Fresh private assets/history preparation and ordinary acceptance remain pending.

Read-only Engine inspection now verifies the approved whole-file SHA-256 and
bounded sidecar footer/manifest through a no-follow regular descriptor. Public
verify_sidecar_checksum_file checks that same descriptor; input inode, length,
permissions, owner and modification/change versions must still match the named
path afterward. SDK compatibility is checked before decompressing assets. No
operator path is reopened for checksum verification, no SDK record is created
and no materialized artifact or reusable restore authority is returned.

The existing streaming tar validator checks complete classic inventories,
state/layout hashes, optional sparse memory/disk digests and exact disk mapping
with the public 64-file chain limit and top-level storage/overlay targets.
Expansion is charged to the declared captured profile
plus the existing nested guest-rootfs allowance, instead of inheriting the pack
cap for large sparse disks. History transport validation accepts only declared
index paths and regular content-addressed objects: 8 MiB per index, 16 MiB of
indexes total, 32,768 entries, 1 MiB decoded per object with a bounded zstd window.
This is an envelope check; scaled history bounds and disk format/chain semantics
remain required before restore admission. Request-private preparation separately
validates the indexes/references described below.

Artifact reads have one finite checkpoint deadline and cancellation checks at
stream reads. Native work metadata/descriptors remain leased by the executing
thread after read-only caller retirement, while sibling control admission stays
available. Mutation observers retain their existing quarantine/uncertainty
semantics. These non-VM checks do not qualify capture, restore, package bytes or
public checkpoint capability admission.

### Checkpointable startup and capture material changes

Unmodified EmbeddedRuntime::start_forkable_machine updates VmRecord.forkable;
portable_checkpoint::capture_to_path updates checkpoint_head after publication.
Both fields remain in SmolBox's material hash. set_checkpoint_head logs a warning
on database failure instead of propagating it into CaptureResult, so SDK capture
success alone cannot prove a correlated source material transition.

Fresh local/qualified-registry checkpointable creation now sets forkable before
original receipt/material publication. It rejects container/layered/dependency
packs and network/port/workload combinations. Ordinary start already honors that
persisted flag, so Engine::start_checkpointable checks original authority without
using the SDK convenience start to promote existing records. Read-only preflight
requires an authenticated running source, exact enrolled runtime PID/birth,
verified templates and the public SDK capture-profile check. It grants no guest
idle assertion, artifact publication or material-transition authority.

Capture now has a distinct entered-intent/material-transition journal foundation;
its coordinator still needs separately bounded staging/worker
collection and successor proof binding the exact published artifact/lineage and
verified source resume. Do not interpret a growth proof as capture evidence, drop
checkpoint_head from the material hash, infer completion from inventory or replay
capture after a lost result. Core/Port source-operation models do not qualify a
running VMM or activate the public checkpoint feature. Crash validation stays
deferred.

The capture transition binds the original material proof, source PID/birth and
previous checkpoint head to an explicit idle assertion/byte bound. Completion
records an independently verified artifact digest/size/head/parent and permits
only the corresponding source checkpoint-head change with source state/PID
preserved. Capture and growth links retain distinct proof domains in one ordered
revision chain. Full file-version compare-and-replace rejects in-place changes;
permits bind their original directory. These journal interfaces currently have
only non-VM boundary models; no SDK capture call or output stream is connected.

### Request-private checkpoint preparation

Engine::prepare_checkpoint_artifact copies only approved bytes under the existing
private owner domain, checks stable source identity and authenticates the copied
artifact independently. Input files become mode 0400 under mode-0700 staging; no
SDK row/reservation or global restore cache is created. PreparedCheckpoint is
opaque, retains its native lease/domain and rejects cross-domain reuse or changed
private input versions. Inspection cannot construct it.

History extraction uses public unpack_checkpoint_history after bounded envelope
validation. Public checkpoint_store::read_manifest/read_manifest_at validate the
SDK index. The independent managed policy reader uses public StoredFile serde and
crates/smolvm-checkpoint/FORMAT.md, not a copied private index implementation. It
requires exact manifest file inventories, checks each referenced object’s decoded
length/content hash, verifies reconstructed declared digests (including zero
chunks), and binds head/ancestor lineage plus nonzero data summaries. Head
resources bind the target approval; retained ancestors use their captured
allocations, allowing history across stopped growth.

Preparation charges copied input plus the bounded history object/index allowance
against a separate aggregate 128-GiB checkpoint staging cap. A separate 128-MiB
SDK-parser allowance supplements normal work metadata without consuming reserved
control headroom or widening registry/command budgets. These allowances survive
caller retirement and prepared-input lifetime. Recognized private-root cleanup
releases them; a substituted/unknown root remains untouched and fences work with
its allowance retained. SDK-written classic/history fixtures and deterministic
metadata/resource models exercise these boundaries without starting a VM.

The format specification and SDK disk_target implementation agree on 64 files per
chain and storage.raw/storage.qcow2 or overlay.raw/overlay.qcow2 at index zero.
Backing indexes use the reserved .smolcheckpoint namespace. Previous synthetic
fixtures did not expose the top-level naming bug; source policy and fixtures now
match the public SDK contract. SDK materialization/installation, disk semantics,
fresh creation/material authority, first-start consumption and bridge/store
integration remain pending. No checkpoint capability is activated.

### Owned checkpoint materialization worker

Engine::materialize_checkpoint_artifact consumes opaque prepared input through
the existing owned worker supervisor. Classic input uses public
extract_checkpoint_sidecar; history uses checkpoint_store::materialize with no
restore base/global cache. No SDK machine record/reservation or VM dispatch is
performed. A protected metadata witness binds source/root/file versions, exact
profile, selected manifest and one caller deadline. Metadata serialization is
bounded at 16 MiB. The source token owns the promoted native lease inside the
collection lease box, so worker retirement retains its domain/files/allowances.

The worker environment fixes SMOLVM_CHECKPOINT_THREADS=4 and supplies only a
fixed system PATH plus the approved library path. SDK CPU fingerprinting invokes
sysctl on macOS; checkpoint inspection/preparation reserve one conservative
metadata child, and materialization reserves that floor plus its owned worker.
This is public SDK metadata behavior, not a smolvm CLI fallback. No BEAM/NIF
process environment or umask is changed.

Decoded staging has a separate finite 2-TiB aggregate cap (the SDK store’s logical
size ceiling), charged from the selected manifest before child entry. One atomic
promotion accounts for the worker, descriptors and witness spool; exact child
collection and spool cleanup precede demotion. Source/decoded allowances and
metadata headroom remain with MaterializedCheckpoint until owned cleanup.
Retirement uses close/retain without signals, replay or late-result promotion.

The distinct CheckpointMaterialized event must match both source and metadata
hashes. Parent re-observation checks output root identity, exact file inventory,
file versions, logical sizes and declared digests. SDK extraction applies 0755
to its fresh output root; the worker tightens that owned directory through a
no-follow descriptor under the still-private source root before proof creation.
It never repairs an existing VM directory. Disk format/geometry and captured
state semantics still require installation/start qualification.

An explicitly selected ordinary non-VM worker fixture exercises both classic and
SDK-written history input, normal helper collection, private cleanup and empty
SDK machine inventory. Three deterministic contracts cover material proof/extra
or redirected files, correlated/retired event rejection and atomic resource
promotion/collection. SDK install, fresh creation/material proof and first-start
consumption remain pending. No public checkpoint feature is enabled.

### Fresh checkpoint installation authority

Engine::create_checkpoint consumes opaque MaterializedCheckpoint, validates the
creation identity and disk top capacities, checks approved templates/domain and
locks the generated machine name. Existing SDK rows or material directories
reject. After SDK-name reservation, exclusive mode-0700 directory creation and a
no-clobber mode-0400 ticket bind name/owner/incarnation plus source/material hashes.
The ticket is not inventory-derived ownership and cannot replace a creation receipt.

A new CheckpointInstall worker kind uses public portable_checkpoint::install and
discard_transport_pack beneath that exact ticketed directory. It verifies source
material, original source/target directory identities and ticket before entry,
then checks pending inputs, exact storage/overlay virtual capacities and protected
installed-file identities. Its distinct expected/installed proof binds the
protected metadata and ticket; generic, crossed or duplicate acknowledgements
cannot promote success. QCOW backing/format semantics remain SDK installer
responsibility; the independent capacity check does not claim filesystem validity.

One atomic install promotion retains decoded source allowance and charges a
separate finite prospective installation allowance, bounded at 2 TiB, plus one
worker and a 2-MiB metadata spool. The collection box owns source, machine gate
and SDK reservation. No signals or late-result promotion are used; unresolved
collection retains the leases, and errors do not delete or replay partial VM
material. SDK preparation reservation release is separate from durable caller
capacity. Parent verification of exact collected output precedes record/receipt
and material-journal publication.

The record uses public MachineSpec::to_record with exact approved resources,
owner/incarnation and checkpoint hash labels, offline bare topology and neutral
cold-start command/env. Explicit forkable/host-UID-owner/history fields bind the
new machine’s own SDK routing. No private restored_record implementation is copied,
no SDK-created row is adopted and no source-machine UID/ownership is reused.
Worker restore COW/tmpfs choices are fixed within the child environment so the
selected path uses private disks and the owned disk-backed VM namespace. These
settings do not modify a BEAM/NIF process or source checkout.

The ordinary macOS development fixture installs synthetic state and sparse disks
without booting a VM, commits only a fresh owned stopped row with original receipt
and material proof, checks pending inputs/resource sizes/neutral routing, and
collects/cleans source work. It does not qualify RAM/device restoration, first
start, helper replacement or public admission. Existing SDK start code explicitly
finalizes and consumes pending live restores; SmolBox first-start proof/uncertainty
integration and ordinary qualification still need completion before capability
activation.

### First-start consumption and uncertainty

SDK embedded/control::launch_from_record detects public pending_dir before
launch and, after agent startup, calls public finalize_live_restore and consume.
SmolBox does not copy that implementation or independently consume RAM during
ordinary start. A private checkpoint-start journal adds controller intent and
correlation: pending, entered with a fresh operation nonce, and consumed with
the same operation and observed enrolled PID/birth.

Its immutable root binds target/domain/name/owner/incarnation, selected source,
captured resources and installation evidence. Root SHA-256 is a material SDK
record label; validation additionally matches the supplied receipt to the SDK
record. Journal reads are no-follow, owner/mode/size constrained (64 KiB) and
bind file versions. Writes are atomic no-clobber or compare-existing-version
updates with synced file/directory. Unknown/missing/crossed journals cannot be
created from inventory or relaxed into cold-start permission. Legacy records
without checkpoint labels/journal retain their existing lifecycle.

SDK-installed readonly files can be hard-linked to private staging on macOS;
removing staging changes target ctime. Initial lifecycle evidence is therefore
re-observed after authorized staging cleanup, with native allowance, SDK name
reservation and machine gate still retained. Independent owner/material/lifecycle
control files are excluded from the SDK installed-byte fingerprint and validated
through their own authority. Full file-version checks remain in use.

Before SDK start, complete pending inputs/captured sizes must still match. Entered
intent is durable before dispatch; SDK failure, cancellation, late observation or
missing completion never permits replay. Only explicit SDK success plus matched
live cached-handle PID/birth and absent consumed inputs publishes consumed state.
Later starts require consumed state and reject reintroduced pending input. Read-only
inspection classifies entered state IdentityUnknown without repairing it.

Normal stop/shutdown can still address an entered restore only when this engine
holds its original enrolled handle and matching live SDK PID/birth. It does not
resolve the journal, claim restoration success or release durable storage capacity.
Explicit quiesced resolution and expanded bridge/store histories remain pending.
Non-VM models use SDK consume on synthetic local files only; no VMM loss, signal
campaign, store interruption or independent CLI race is exercised. Real captured
RAM/device qualification and public checkpoint admission remain pending.

### Owned capture coordinator and worker

`Engine::capture_checkpoint` now takes an exact creation/material receipt,
operation ID, explicit idle assertion, byte limit and one caller budget. It
preflights checkpointable source eligibility, holds the machine gate and native
work/staging allowances, prepares private metadata, and persists entered capture
intent before dispatch. The worker receives exact SDK domain paths through its
private environment; it independently checks the default SDK DB/VM paths, private
directory and DB identity, entered source intent and live enrolled PID/birth.
It calls the unmodified public `EmbeddedRuntime::checkpoint_machine` without
another SDK source flock. Capture uses private staging and zero prepared-cache
retention. The SDK owns source pause/resume; neither preflight nor the idle
assertion attests actual guest idleness.

The capture-specific terminal proof binds metadata/operation, exact output
identity and digest/size, lineage, and resumed source material/PID. Generic file
acknowledgments, crossed proofs and retired events cannot complete capture.
Collection must finish normally before parent source rechecks, independent output
hash/version checks, and the journal transition publish a new receipt. Output is
an opaque `CapturedCheckpoint` retaining native allowances and private bytes;
one-time chunk streaming shares cancellation/deadline and validates hash/version.
This is an engine boundary, not yet a public Port capture or durable-store API.

Entered uncertainty keeps staging and its charged allowance; it cannot replay or
invent success from SDK inventory. The source gate releases after collection so
the same enrolled engine may stop the exact source normally. Stop leaves capture
and durable material unknown and grants no storage release. Pre-entry retirement
cleans trusted private staging; unknown/replaced staging is preserved and fences
admission. Capture workers follow the supervisor's no-signal collection path.
SDK capture may stage complete disk chains and RAM, so its separate conservative
decoded-material allowance is retained in addition to the bounded artifact limit;
these admission allowances are not filesystem quotas.

Deterministic tests cover distinct proof correlation/retirement, prepared abort
versus entered fencing, exact source-stop predicates, private cleanup/replacement,
stream cancellation, failed consumer and replay rejection. No live capture VM or
crash campaign establishes qualification here. Public routing/publication and
saved histories, ordinary running-source resume and exact-package platform/public
consumer qualification remain pending; public checkpoint admission stays disabled.

### Exact completed capture observation

Protocol-2 `inspect_capture` takes the original receipt, operation ID and exact
capture request. It is an observation under the existing inspect capability and
separate checkpoint feature gate. The engine validates its domain/database,
original incarnation marker and bounded journal while holding the observation
allowance and source gate; cancellation is checked before and after the read.
`capture_presence` returns only the recorded correlated capture transition, or
null when no matching completed entry exists. Null supplies no quiescence,
artifact absence, mutation or replay authority. No source/SDK row is adopted.

Rust wire and Elixir `CaptureTransition` reproduce canonical SDK-independent
engine evidence without rewriting its hashes. They validate request bounds/idle
assertion, source PID/birth, distinct lineage, original root, consecutive revision,
request digest, capture-specific chain digest and immutable origin. Helper and
BEAM channel correlation reject crossed previous receipts/IDs/requests and any
output bytes. Optional lineage parents and nullable completion are explicitly
present; omission/unknown fields are rejected. Shared synthetic fixtures validate
against the engine too. This prepares durable lost-result observation; public
capture streaming, identity/store histories and resolution still need integration.

### Capture checkpoint byte transfer

Protocol-2 `capture_checkpoint` uses an original receipt, operation ID and typed
capture request. It remains checkpoint-feature gated and uses the existing read
capability. The Port adapter calls the shared engine and forwards private captured
bytes through a dedicated `checkpoint` stream. Its `captured` terminal carries
the exact capture transition. Both channels bind that transition to the original
request and require emitted byte count equal to the artifact's declared size.
After SDK capture, any stream/metadata/deadline failure is uncertain, even if no
byte was emitted. No transfer error can authorize capture replay.

Checkpoint output has a separate bounded 1,048,577-event allowance for the
64-GiB artifact cap. Existing 64-KiB chunks, frame size, queue bounds and byte/event
credits remain unchanged; ordinary command/file total limits stay fixed. Errors
after a long checkpoint stream may carry its extended sequence, but request
correlation and ordinary-stream event limits still apply.

`CaptureStream` hashes delivered chunks incrementally. `Call` requires a consumer
before submission, emits only checkpoint chunks, and acknowledges credit only
after an explicit `:ok` consumer return. Failed/throwing consumers, oversized
chunks, over-limit artifacts and wrong streams retire capture; the final transfer
requires exact digest/size and original operation binding. No whole-artifact
buffer is returned. A deterministic peer proves total transfer can exceed the
ordinary response buffer while each accepted chunk remains bounded, and that no
credit follows consumer failure. These tests perform no SDK/helper/VM launch.

Public backend policy/destination selection, no-clobber local artifact publication,
durable source/capture histories and lost-result resolution remain pending.
Ordinary live SDK capture/source resume/platform/public consumer qualification is
still pending, and the current public SDK descriptor does not enable checkpoints.

### Durable capture receipt evolution

Elixir material history now preserves ordered growth and capture proof domains,
canonical roots, receipt/revision continuity, unique operation IDs, geometry,
lineage and the respective immutable witnesses. `Identity.material_history`
retains the complete chain when capture evidence is present, including on attached
commands. Original creation stays immutable; native capture updates only current
source observation and its typed captured history. Post-growth captured profiles
are computed from their position in the history. Structural mixed-history tests
do not change the HTTP-compatible public exclusion of checkpointable growth.

`CaptureOps` accepts native captured success only with the exact correlated
transition and original source PID/birth. Result/transition/current observation
publish in one guarded store mutation. Rejected proofs keep old intent/material
and all reservations. HTTP records reject native transition evidence. Codecs use
v24 only for native capture histories or inherited chains, preserve older default
bytes, and reject new-field presence in earlier envelopes. Runtime requires the
separate capture-history reader before a future checkpoint-capable helper may
enroll. Memory and PostgreSQL share an ordinary atomic capture contract; these
models never call SDK capture or launch a VM. Public publication/routing,
unknown-result resolution and actual running-source qualification remain pending.

### Scoped capture destination and publication

The embedded backend now binds its active capture snapshot to the exact operator
policy and fingerprint output path, original checkpointable source and current
receipt. Runtime uses assigned pinned references for preflight/dispatch and carries
the native proof into atomic store advancement. Follow-up capture preflight uses
current material authority, while initial creation remains immutable. Manifest
verification compares SDK version independently of engine health identity.

Controller publication independently hashes its retained descriptor, checks
private root/directory and named-file identity, bounds consumer bytes and keeps
partial evidence on failure. Exclusive creation and no-clobber hard-link
publication preserve existing output. File and directory metadata are synced;
directory descriptors use the documented
[OTP 27 directory mode](https://www.erlang.org/docs/27/apps/kernel/file.html#open/2).
No controller path crosses the native protocol. The public policy contract still
requires the operator to protect the approved root from path replacement.

An optional transport chunk limit allows smaller response windows without
changing material hashes. Nonempty artifact bytes bound finite lifetime sequence
count by 64 GiB plus framing allowance; fixed ordinary event limits and all
per-chunk/queue/credit limits remain unchanged. Synthetic publication/channel
models establish these controller boundaries, not live SDK source qualification.
Public checkpoint admission remains disabled; unknown-result resolution and
ordinary package/platform/public consumer qualification remain pending.

### Completed-proof unknown capture resolution

Backend capture observation looks up only the exact completed native journal
operation before inspecting with its new receipt. Complete material history and
prior receipt/ID/request must match; null conveys no completion, adoption or replay
authority. Promotion is ephemeral. Automatic recovery may classify the owned
source but retains interrupted/unknown capture intent, original stored receipt and
reservations without importing a recovered proof.

Explicit public resolution freezes native dispatch, serializes with reconciliation,
verifies source observation and applies one guarded store transaction. A matching
completed transition may advance the source even when artifact delivery stayed
unknown. Result remains nil, state is resolved_unknown and retained artifact disk
allowance survives. No byte/file presence supplies captured success, and duplicate
intent never replays. Deterministic running/stopped source contracts pass Memory
and PostgreSQL without a helper/VM launch or persistence interruption.

Entered source capture without completed journal evidence remains unresolved and
fenced. Explicit retained-stage/native-budget and material resolution still need
implementation and qualification; source stop alone cannot complete capture.
Public checkpoint feature admission remains disabled.


## Container export conversion inputs

`QualifiedExportSource.prepare_container_export` now retains the stopped source
receipt/gate/root/deadline and promotes its existing descriptor allowance before
opening the exact logical storage disk. It supports the registry-container path;
local/imported layer caches still require separate authenticated grants. Raw and
QCOW descriptor handling uses the same bounded engine reader as bare exports.
Reads create no scratch or VM and grant no conversion/publication success.

The prepared handle produces an exact cached Query and consumes byte-bounded,
sequence-bounded image metadata into an inert conversion plan. Reference,
digest, native platform, layer count/digests and metadata bounds reject before
building guest paths. FlattenLayers streams (`output: None`) with the persistent
overlay first and cached layers reversed from manifest order. This matches the
actual SDK collector and agent `lowerdir+` implementation; the protocol field's
older bottom-up comment contradicts both. No network rebase or tag resolution is
introduced. Manifest seeding uses the public SDK helper to preserve machine env
over image env, user precedence, original entrypoint/cmd/workdir, network and
resource values. A plan is bound to the exact source-record digest and is
rechecked against that held source before metadata can be returned. It attests
neither cached-image authenticity nor layer production on its own.

Four private non-VM contracts cover these semantic/boundary checks, source gate
and descriptor retention, changed source storage, cancellation and substituted
owner. No convenience collector, implicit SDK helper, stale reaper or SDK
lifecycle call is invoked. Enrolled auxiliary conversion VM creation/collection,
account-approved disk/UID/mount policy, authenticated cached-query collection,
bounded flattened tar staging, container packing and public ordinary acceptance
remain pending. Local/imported source semantics remain pending. Public exports
stay disabled and crash validation remains deferred.


## Explicit export conversion resources and composite admission

Future exports catalogs now carry the operator's exact slots/CPU/memory/disk
resource grant as optional `conversion_resources`. Rust validates the same
bounds as ExportDestination; staging cannot exceed the granted disk capacity.
Omission remains omission on serialization and supplies no conversion grant.
Existing destination/TLS identity, cached reader checks and bare publication
are unchanged. No request can select an independent resource grant. Public SDK
packages still omit exports, so this introduces no public helper activation.

The shared engine plans four guest CPUs and 1024-4096 MiB of guest memory from
that grant, leaving 128 MiB for host conversion work without consulting SDK
export environment overrides. Registry conversion uses an explicit one-GiB raw
metadata disk: cached source directories are bound into the helper and the flattened tar streams to the host,
without extraction/re-pull on helper storage. The plan counts that disk together
with conservative two-times source COW backing,
two GiB for the one-GiB root overlay including QCOW metadata, flattened tar and
final pack. Their sum fits both the granted disk capacity and native staging
ceiling. Insufficient/overflowing plans reject before allocation. The approval
has its own canonical resource hash; these values supply no inode/child proof.
Raw disk format and actual UID/mount/resource behavior remain to be qualified.

Prepared container inputs can now atomically promote the existing source job to
24 descriptors and two children for the enrolled VMM plus agent conversion
worker. It consumes no second work slot or metadata grant and preserves eight
control descriptors. Changed grants/caps conflict within the same handle;
repeat identical reservation does not double-charge. Quarantine/exhaustion
cannot partially promote or release existing capacity. Staging reuses this
whole-pipeline allowance. No child or scratch is actually created by reservation;
future execution must retain that same handle/lease until actual collection.

Controller container request sizing, protected auxiliary-root/child enrollment,
UID/COW/device grants, SDK launch/collection, reserved-worker handoff, tar/pack
staging and ordinary exact-package acceptance remain pending. No auxiliary VM
or SDK lifecycle test was run; crash qualification stays deferred.


## Protected pre-launch helper scratch

Prepared container inputs can now enroll schema-6 helper scratch after checking
the original full export admission and freezing the conversion resource plan.
The existing export byte ceiling is retained before allocation. Reserved records
bind a deterministic helper name, operator grant and exact budget to the source/
operation/request. Owned records additionally bind the newly created empty
private directory's device/inode/UID and modification/change timestamps. Helper
paths derive only from the bound VM namespace; existing paths never enroll.
The movable scratch handle retains source/job leases and both directory anchors.
A mandatory SDK namespace check rejects a process-cache/bound-directory mismatch
without entering any SDK lifecycle API. Database-only fixtures supply no such
SDK authority, and tests operate only in their private directories.

This schema expressly grants no SDK entry, launch or publication. Helper records
cannot become Ready/Packed or open the existing bare disk/artifact writers. An
empty pre-launch helper can be retired explicitly: protected Removing precedes
descriptor-relative rmdir and parent sync, then Removed precedes stage cleanup.
The cleanup hash binds the helper/resource/root authority in its own domain and
grants no VM absence. Source-row removal does not invalidate protected scratch
cleanup. Known Removing plus an absent directory can complete explicit cleanup;
unproved Owned absence, foreign contents and substituted directories retain
capacity. Exact forward protected/cache reconciliation recovers only cleanup,
never a writer. Schemas 1-5 retain their existing read/cleanup contracts and hash
bytes; current nonterminal records restore byte capacity and quarantine.

Private filesystem models cover these boundaries. Child enrollment, SDK setup/
launch/collection, actual UID/COW/mount/device behavior and retained-worker handoff
remain pending, alongside container tar/pack construction, controller sizing,
local/imported sources and ordinary exact-package acceptance. No VM/lifecycle or
crash campaign ran. Public exports remain disabled and crash validation deferred.


## Collected storage-only SDK initialization

The shared engine now has an owned SDK storage initializer for conversion
scratch. Before entry it rechecks the source/disk and SDK VM namespace, verifies
prepared package templates/host context and requires the SDK library selector
to match the approved canonical library directory. It retains the same source/
job/directory leases on the owned executor through the original deadline. The
SDK batch uses only public ensure_vm_dir, explicit sparse StorageDisk/OverlayDisk
constructors and create_disk_overlays for a private source COW view. Namespace
identity is checked again before the global SDK directory call; disk sizes are
explicit. No AgentManager/default-rootfs resolver, cache extraction, formatter,
manager start, CLI/server fallback or VMM launch is called by this batch.

Protected schema 7 records SdkPreparing before SDK filesystem entry. A returned
batch, including a partial failure or retired observation, records SdkPrepared
with exact private regular-file versions and directory identity. This proves
collection of this storage-only batch, not bootability, VM absence or guest
startup. Four bounded names are permitted; the name binding is byte-bounded and
must match the expected helper name (or a partial prefix after failed setup).
Zero-length partial files can be retired. Unknown names, links, replaced files,
uncollected entry and repeated initialization retain the fence and capacity.
File snapshots are private and cleanup hashes bind them in a new domain;
schemas 1-6 retain their prior bytes and cleanup semantics.

Explicit cleanup removes only matching collected file versions under protected
Removing before directory removal. Recorded file-removal prefixes and exact
protected completion/cache lag permit cleanup only, never reopening a manager
or writer. The actual SDK sparse disk APIs are exercised with explicit private
fixture paths; modeled name/partial allocation and completion prefixes are not
SDK namespace/COW/VM qualification. Database-only fixtures cannot enter the full
initializer. Correctly scoped ordinary library/COW/package qualification and
helper child enrollment, manager launch/collection, account/device/mount policy,
reserved-worker handoff, container pack/controller sizing and other source modes
remain pending. Public exports stay disabled and crash validation deferred.


## Exact enrolled child identity after SDK return

Boot dispatch finalization now returns an opaque enrollment containing the
original pending operation, helper/machine hash, owner epoch and the child
identity captured before SDK execution. Its fields cannot be constructed from
inventory. Legacy finish callers keep their existing result shape. Exact SDK
PID matching and protected pending-record checks still precede finalization;
substituted PIDs retain the unresolved pending/actor evidence and replacement
fence. Finalization can return the original identity after normal child exit.

Owned OCI startup now persists that enrolled birth rather than sampling the PID
again after SDK return, avoiding a lost/reused PID race. It checks original
machine/epoch correlation and exact SDK PID before recording launch evidence.
This is birth evidence, not current guest liveness or readiness inferred from
inventory. Normal child-exit and substituted-PID contracts cover the boundaries.
Conversion helpers still require an owned retention registry/manager lifecycle
before VMM launch can be added; SDK setup and scratch qualification remain
separate. No helper VM, forced termination or crash campaign is invoked here.


## Engine-owned initialized storage retention

Successful storage initialization now inserts its collected storage/source into
an engine-owned bounded registry before checking the retiring caller's deadline.
The returned token borrows/observes that entry; dropping it releases no source
machine gate, native work/child/descriptor/metadata lease, directory anchor or
SDK disk handle. Late observer retirement leaves the same collected storage
owned by the registry. Identity includes original source/operation/request and
insertion additionally requires the same owner-domain Arc. Tokens cannot be
adopted by a different registry/engine instance. The registry contains only
initialized storage, never an SDK manager or VMM in this revision.

Explicit positively quiesced cleanup routes exact retained identity before
trying the source gate already held by that entry. Live borrowing, changed
request, cancelled budget, contention or file/root uncertainty reject without
removing the entry or releasing its leases. Matching cleanup uses the original
stage owner token; only successful protected filesystem retirement removes the
registry entry. Mutex acquisition is nonblocking for bounded control budgets.
Normal engine replacement restores only protected staging capacity/quarantine,
never a retired token or initialized object. Schema-7 records and prior cleanup
proof shapes are unchanged. No registry inventory supplies VM ownership.

Private storage models cover caller drop, held source/resource capacity, live/
changed/unquiesced/cancelled/failed cleanup, foreign files, registry/domain
substitution and normal replacement. VMM manager retention/launch/collection,
owned worker handoff, container pack construction and ordinary full-namespace/
library/COW/platform qualification still remain pending. This change invokes no
helper VM or SDK lifecycle operation and keeps crash validation deferred.

## Retained unstarted SDK manager preparation

A retained storage token can now prepare an unstarted SDK AgentManager inside
its original engine-owned entry. Preparation first rechecks source/disk/collected
helper files and requires the SDK name-derived directory to equal the bound
helper namespace. The rootfs is selected only as the approved package library
parent's agent-rootfs directory, after template/host/library and export asset
catalog checks. The directory is anchored and the public SDK rootfs resolver is
called with an explicit path, never its default/cache extraction branch. Guest
sbin/init symlinks are tested by symlink_metadata as in the SDK; host rootfs
redirects and invalid package layouts reject.

SDK disk handles are reopened from the exact collected storage/overlay paths,
then passed to public new_named. It starts no VMM, formatter or workload and
creates no disks. Source and collected files are rechecked before/after; the
manager's name, own child absence and storage/overlay paths are checked against
the original helper. The registry retains the manager and rootfs anchor with
storage/source leases. Repeat preparation rechecks the existing manager. Failed
preparation preserves retained storage and explicit cleanup; current helpers
remain schema 7 with no launch authority. The borrowing token supplies no SDK
manager access or inventory-derived ownership.

Private tests prove namespace rejection keeps capacity/cleanup and explicit
package rootfs selection accepts guest init links while rejecting missing or
redirected host roots. These boundaries do not qualify positive full SDK manager
construction or guest boot; manifest/archive/tree integrity and exact-package
ordinary qualification remain required. VMM retention through entered launch,
child enrollment/start/collection, UID/device/mount policy, owned worker handoff
and container pack/controller integration remain pending. Crash tests stay
deferred and public exports disabled.


## Source-bound conversion launch configuration

Unstarted manager preparation now retains an ExportDisk descriptor view for
export-source.qcow2 and a frozen launch configuration. Capture uses the existing
bounded QCOW chain/table scanner with opaque export-byte semantics, verifies
logical size and requires the immediate backing path and full captured file
version to equal the already retained source. Source and view are rechecked;
a matching-size foreign disk, raw/unbacked view or changed source cannot qualify.
Protected schema-7 scratch must have all four expected files, exact helper name
and raw disk lengths, plus the same resource plan retained by the source job.
Partial collected batches keep cleanup authority without obtaining launch inputs.

Configuration supplies the explicit offline CPU/memory/storage/overlay grant and
one writable QCOW extra disk. Ext4 journal replay is confined to the private view,
following the public SDK export convention; the original source is never attached
writable. UID sharing selects only the held source directory. Defaults grant no
network, GPU/CUDA, fork/snapshot, host mount, pack mount, credential interceptor or
extra caller-supplied disk. The manager retains these inputs and rechecks them;
no launch API is called and schema 7 still conveys no VMM authority. Privileged
Linux UID/mount behavior is not qualified by selecting that directory.

Four private model tests cover raw/QCOW backing identity and logical bytes,
foreign/unbacked views, protected resource/configuration binding, and partial
collected storage (including a short helper name) retaining cleanup. A separate
explicitly selected ordinary filesystem-only SDK witness creates private overlays
using public create_disk_overlays for both retained raw and QCOW sources, then
checks them with the same descriptor scanner and logical reader. It loads
libkrun but constructs no manager or VMM and accesses no SDK machine namespace.
The tested macOS libkrun SHA-256 is
03b62510617705307e7ca4fa60c8a499a42ea536bd6aa29a14e2a4ed258384b3.
This is library filesystem evidence, not positive full initializer, manager,
guest boot or export/import package qualification. The opt-in witness is selected
by its exact test name; deferred campaigns stay unselected.


## Entered conversion launch and exact returned child

The retained conversion token now exposes one owned SDK manager start. It uses
the source's original cancellation/deadline, without granting a fresh budget or
work slot. Preparation/source/assets and the current engine boot epoch are
rechecked before dispatch. A root-process owned thread holds the original entry,
manager, source gate, domain and resource leases across blocking SDK entry and
caller retirement. Registry metadata and per-entry work locks are separate, with
nonblocking access; an executing entry does not hold the whole registry lock.
Both observation slots remain available under the retained conversion demand.
The SDK boot executable selection is checked again within the owned thread; no
CLI/default-executable fallback is authorized.

Protected staging schema 8 records LaunchEntering before SDK entry, binding the
original helper/source/request/resource/file snapshots to the opaque boot intent.
The intent now contains creator PID/birth/UID and epoch-directory device/inode in
addition to epoch, machine hash and operation. The actor epoch is bound to the
engine domain and original directory; matching a label in a different directory
cannot substitute for it. LaunchReturned accepts only the exact opaque enrollment
produced by the pre-exec actor ledger. It retains the original child PID/birth/UID
even if the SDK result arrives after expiry or reports an error. No process sample,
PID file or inventory supplies that enrollment. SDK success and unchanged stopped
source are separately required before returning success to an active caller.

Returned dispatch is not normal child collection. Both schema-8 states reject
replay, storage-only cleanup and cleanup-proof generation. Normal reopening
restores staging capacity and quarantine without adopting a manager/token or
inventing child absence. Schemas 1-7 retain their original shapes/proof hashes;
older engines reject schema 8 before mutation. This internal lifecycle adds no
public protocol capability or helper-result proof. Public exports remain disabled.

Four private record models cover entered/returned fences, foreign name/domain/
epoch, crossed enrollment despite equal epoch labels, and normal reopening with
capacity retained. Modeled actor records use synthetic identities and start no
process or SDK lifecycle. A separate per-entry contention model proves metadata
access and two credited observation slots while work is held, then checks retained
source leases through explicit cleanup and worker release. The existing private
namespace test also rejects the new start method before manager/VM entry.
Positive full SDK helper startup, normal child collection, bounded runtime-file/
rootfs retirement, privileged UID/device/mount policy, worker handoff and actual
container flatten/pack/public acceptance still require implementation/ordinary
qualification. No live helper or deferred crash campaign ran for these models.


## Original conversion child collection

The retained manager now keeps its opaque pre-exec enrollment independently of
returned-record publication. Collection can reconcile that retained SDK return
without relaunching. A retained token has explicit collection; quiesced control
can also select the exact original entry after its borrower retires. Foreign
source/request, active borrower, missing manager, cancellation or contention
reject before SDK work. Persisted child fields cannot recreate the manager.

Collection runs in an owned thread with retained source/job/domain/manager leases,
using the caller's remaining control deadline capped at thirty seconds. It uses
the original actor ledger even when new launch admission is fenced. SDK normal
stop requires this manager's own child PID and the original enrolled birth to
match; no observed manager or PID-file stop fallback is constructed. If the exact
child has already been collected, the manager's handle is cleared with public
mark_stopped, without an orphan shutdown. SDK stop is not initiated for an already observed reused
PID. A failed/unknown entered stop is not implicitly replayed while its child
remains uncollected; a later explicit control may observe original collection.
While the SDK stop call runs, an opaque collection dispatch keeps the original
boot actor pending. Sibling sweeps cannot reap it or consume its exit status.
Only actual SDK return (including an error) clears that pending record; an
unresolved dispatch retains the epoch fence. It grants no child collection.

Opaque BootCollection is produced only from the original enrollment, matching
creator/epoch-directory/domain authority, positive original-child absence and
quiescent helper actor ledger. The ledger can reap the exact exited owned child;
transfer status still belongs to its supervisor. Collection is not guest fsync,
flattening or artifact/publication proof. Schema-8 LaunchCollecting is recorded
before stop; LaunchCollected accepts only the matching opaque collection. Actual
late collection is retained before refusing caller success. Both phases still
reject restart, storage-only cleanup and cleanup-proof generation. Staging/files
and source resources remain held until future separately bounded runtime-file/
rootfs retirement. Older schema-8 readers reject the new phase names before
mutation; package approval and reader-first deployment remain required.

One ordinary non-VM child test covers live refusal, normal pipe-close/wait exit,
exact collection and foreign epoch rejection without signals. Private models
cover crossed/duplicate collection, all four launch phases surviving normal
reopen with capacity/quarantine, exact retired control and cancelled/unquiesced/
missing-manager rejection. A machine model keeps collection's original ledger
accessible under launch quarantine without granting a boot. These checks qualify
these boundaries, not SDK helper shutdown or positive guest startup. No live
helper or deferred crash campaign ran; public export admission remains disabled.


## Collected helper runtime and rootfs-marker retirement

Original manager collection now enrolls bounded post-launch file custody after
matching opaque child collection. Protected staging schema 9 snapshots the exact
helper directory, mandatory name/storage/overlay/COW files, bounded optional SDK
config/log/lock files and stale agent socket. Each entry captures type/mode,
owner/single-link checks and device/inode/length/mtime/ctime. Unknown files,
directories, links, malformed name binding and over-budget inventory reject
without gaining retirement authority. The twelve-file inventory follows the
unmodified SDK manager paths; config files cap at eight MiB, individual logs at
sixty-four MiB, and aggregate metadata/file lengths fit the frozen private-disk
grant. Disk snapshots supply custody, not filesystem/export correctness.

The retained package rootfs anchor supplies only the exact SDK readiness marker
for that helper hash. Present-marker version or positive absence is captured;
other rootfs contents/markers are not selected. Repeated collection verifies the
existing schema-9 custody without repeating SDK stop or enrolling new files.
After borrower retirement and explicit quiescence, cleanup verifies all current
versions before publishing Removing, then unlinks only captured names through
held directory descriptors. Partial removing records permit only missing captured
entries. Marker and helper directory absence are verified and synced before
staging/source accounting releases. Failed/cancelled/uncertain cleanup keeps the
entry and leases. The completed child record alone still cannot grant deletion.

A distinct cleanup hash binds the schema-9 runtime/rootfs-marker snapshot and
original boot/child/resource/source/request evidence. Public cleanup proof shape
is unchanged. Schemas 1-8 retain their omitted-field shapes and existing proof
rules; earlier readers reject schema 9 before mutation. Reopening restores
staging capacity and quarantine and allows explicit version-bound removal, never
manager/child adoption or export replay.

Three private filesystem models cover marker-present/absent cleanup with stale
socket and other rootfs files preserved; changed files/markers, unexpected marker,
unknown inventory/directory, symlink, hard link and oversized log rejection; and
recorded partial removal followed by normal engine reopen. No SDK manager or live
VM is involved. These models do not establish actual helper startup/shutdown,
all SDK-produced file inventories, privileged UID behavior, package rootfs
integrity or export/import semantics. Public exports remain disabled and crash
campaigns deferred; exact-package/platform qualification remains required.


## Bounded streamed container layer I/O

The shared engine now has isolated-worker I/O for a FlattenLayers request with
no guest output path. It validates the retained-plan guest path grammar, rejects
nonempty/nonprivate/linked spools before connection, and sends the public SDK
protocol encoding. This function creates no manager/VM, claims no source ownership
and grants no publication or worker-collection authority. It still requires the
original parent/supervisor to authenticate the helper socket and retain admission.

The verified SDK's guest producer fills sixteen-MiB data chunks, checks tar exit
status and sends a terminal DataChunk. Receiving the whole base64 JSON frame plus
its decoded payload would exceed the desired working-buffer bound. The new decoder
consumes that pinned encoder's canonical envelope through a header-capped reader,
strict base64 quartets and sixty-four-KiB buffers; it never allocates a whole large
frame/payload. Per-frame raw size, aggregate output, frame count and original
absolute deadline/cancellation are bounded. Invalid prefix/suffix/base64, missing
termination, guest error, oversize or cancellation produces no layer evidence;
partial private bytes are not a result. Accepted termination syncs the file and
returns only byte count/SHA-256. It does not verify tar contents or export semantics.
The canonical envelope is tied to the verified SDK encoding; an official SDK
upgrade requires corresponding codec compatibility qualification.

Five non-VM tests cover SDK-encoded sixteen-MiB payload plus terminal digest;
fragmented reads, binary bytes/base64 quartets and empty terminator; missing
termination/guest error/size/header/base64 faults; explicit mid-frame cancellation;
and pre-entry path/output/spool rejection. Ordinary loopback peers use SDK types
and bounded accept/socket deadlines. macOS requires setting socket receive timeout
before transfer rather than resetting it after peer close. No SDK lifecycle,
helper loss, watcher or destructive CLI campaign is involved. The engine now
explicitly depends on the already-locked base64 0.22.1; upstream bytes/versions
are unchanged.

Mount/cache-query bootstrap, the owned supervisor request/proof/credit integration,
parent FD/lease handoff, protected tar registration, container packing and public
ordinary qualification remain required. The I/O result is not a completed worker,
qualified guest-produced archive or product capability. Public export admission
stays disabled and crash validation deferred.


## Fixed conversion mount and cache-query bootstrap

A qualified prepared source can now freeze worker input only after its original
conversion resource grant is reserved. Input binds schema, exact stopped record
hash, planned maximum flattened bytes and the original monotonic deadline. The
metadata is capped at eight MiB, contains no ownership grant/receipt and has
redacted Debug. Caller cancellation and remaining deadline cannot be widened.
The parent still has to retain the actual source/job/helper/worker authority.

Conversion-worker I/O now preflights the empty private output before any guest
operation, mounts only the private third disk (/dev/vdc) read-only at the fixed
source path, and bind-mounts only layers/configs/manifests into the helper store.
Fixed guest shell argv uses public SDK VmExec wire types with remaining timeout;
no image/workload/user strings are interpolated into commands. Each operation
uses a bounded deadline-aware socket; nonzero setup status stops the sequence.
No pull, registry credentials, rebase, source boot, arbitrary host command or
local HTTP/CLI fallback is introduced.

The helper then queries only the frozen digest-pinned registry reference.
A header cap precedes streaming typed CachedImage decoding, bounded sequences,
strict fields and exact reference/digest/platform/layer checks. This avoids a
large serde Value tree and second full cached-image parse. The existing plan
validator consumes the typed image directly, preserving actual topmost-first
upper/layer precedence and image environment/user metadata. Only that validated
plan reaches bounded FlattenLayers I/O. Results bind input hash, plan and terminal
layer bytes/hash, but grant no source/child/worker custody, tar correctness or
publication authority. Failures after the first mount preserve uncertainty.

Four non-VM SDK-encoded loopback tests cover exact setup/query/flatten sequence
and inherited metadata; failed mounts, missing cache and foreign digest stopping
before flatten; cached reply header cap and empty archive rejection; and frozen
hash/deadline/cancellation/spool rejection before guest mount. The source-grant
model also checks worker input cannot precede resource reservation. These peers
are not guest/filesystem qualification. Owned supervisor metadata/proof/credit
integration, actual FD/lease handoff, protected tar registration, packing and
ordinary exact-package/platform acceptance remain pending. Public exports stay
disabled and crash validation deferred; SDK source/version remains unmodified.


## Owned conversion worker and collected private outputs

The retained entry now dispatches exactly one conversion worker using its existing
source conversion reservation and original deadline. No second engine, work
reservation or SDK lifecycle occurs in the worker. The parent authenticates the
started original manager and derives its exact socket. Request metadata is bounded
to eight MiB. Distinct 0600 regular single-link layer/plan spools are opened by
recorded device/inode before guest entry; the input is read-only 0400. Plan bytes
are capped at twelve MiB under the existing 32-MiB metadata reservation. Direct
struct visitors bound cached-image and plan sequences during decode, avoiding
serde internally tagged enum buffering of a complete body before validation. Flattened
bytes use only the explicit conversion maximum; ordinary command/file limits
remain unchanged.

Ready and one small Converted terminal bind frozen input hash, layer length/hash
and plan length/hash. No large payload enters worker control IPC. Generic progress,
acknowledgment, limit, foreign/oversized proof, duplicate or retired terminal events
do not complete conversion. Failed requests confer no output authority. The
supervisor selects job-worker mode and the existing no-signal retirement path.
A collector retains original source/job/worker guards and both spools through
actual child collection; late terminal evidence cannot revive an observer.

After successful normal collection the parent checks modes, links, original
identities, exact sizes and incremental hashes before parsing the bounded plan.
It rechecks source/overlay/environment/user constraints. The resulting opaque
handle retains source/helper accounting and bounds each positional read to 64 KiB,
checking the captured file version before/after reads. Its worker/output token
fences helper collection and explicit retired cleanup until released. Attempted
conversion cannot replay through the retained entry.

Private loopback and protocol models exercise frozen input, writable identity,
exact terminal correlation and invalid evidence. An explicitly selected ordinary
helper-process fixture checks actual worker collection, parent rehash rejection
and lease retention using a local SDK-protocol peer; no VM launches. This does not
qualify actual helper mount/cache behavior, tar correctness, SDK lifecycle or
platform export/import. Protected tar registration/packing and whole-pipeline
output credit remain required. Public exports remain disabled, crash validation
deferred and SDK source unmodified. Changed helper bytes carry no historical
package/platform qualification.


## Protected collected-layer custody (schema 10)

`RetainedConversionStorage.register_conversion` consumes only the opaque output
of that same original retained entry. It rechecks source, started manager, plan,
original deadline/cancellation and both private worker outputs. A crossed entry
cannot supply staging authority. There is no path, digest-only or detached FD
constructor. The caller's existing conversion job/FD/staging reservations remain
held; the original bounded plan is retained in the entry after registration.

A new optional protected layer field is present only in schema 10. Entering/ready
states bind frozen input hash, plan hash, fixed layer.tar name, bytes/hash and the
original file version. Earlier schemas omit the field exactly; they reject a
layer field or a schema downgrade. Existing cleanup proof shape stays schema 1,
with a separate container-layer hash domain binding helper/runtime/layer/files
while excluding only mutable retirement phases. Schema 1-9 hash inputs stay intact.

Entered intent precedes a descriptor-relative exclusive rename of the collected
worker's original inode into the held staging root. No second tar is copied or
charged outside the grant. Source and destination are held directories, original
FD/path versions match, devices must agree and destination replacement has no
fallback. Post-move identity, read-only mode, file/directory sync and incremental
rehash precede ready registration. Partial/late failure retains entered ownership;
it does not retry the move, adopt the target or grant publication. The consumed
worker/output lease is released only when the handoff call returns.

Helper collection and runtime custody preserve schema 10. Full cleanup checks
layer identity/mode and exact stage inventory before retiring helper files. Pending
handoffs permit only the original inode with unchanged content dimensions and the
expected rename/chmod metadata evolution; ready files require their exact captured
version. A protected cleaning phase permits missing already-removed files. Changed
or unknown payloads retain the entire allowance. Normal reopening restores capacity
and quarantine for explicit cleanup only; it never reconstructs a worker, writer,
manager or live ownership from tar bytes.

Five private non-VM tests cover inode-preserving registration, helper collection
and cleanup, modeled before/after move/chmod boundaries with normal reopen, invalid
spools/destinations/cancellation, changed/unknown inventory and schema restrictions.
These are filesystem/ledger models, not actual helper mount/tar/export qualification.
Container packing, whole-pipeline output credit and ordinary platform/public
consumer gates remain pending. Public exports stay disabled; crash validation
remains deferred and no SDK/research source is modified.


## Retired-helper container packing and publication (schema 11)

The original retained token now consumes its registered conversion plan only after
its original manager supplies opaque child collection and exact runtime custody.
`pack` never launches/stops a helper or reacquires work admission. Explicit bounded
helper retirement uses cleanup control admission, verifies exact layer/runtime
inventory, removes only captured helper files/marker and preserves the tar and
source/work/staging leases. New schema 11 records ready/packing/packed state with
the helper removed. Unsupported older schemas reject the new state before mutation;
schema 1-10 serialization/hash inputs stay unchanged.

Packing intent binds the original artifact maximum. A separate entered writer
record precedes create-new output, and its empty original inode is journaled before
body writes. Failed/uncertain entry cannot reopen a writer. Cleanup accepts partial
content only at the registered inode and within its cap; an unregistered replacement
or linked/unknown output retains capacity. Normal reopen restores quarantine and
cleanup authority, never a pack writer or publication replay. Schema-11 cleanup
uses a distinct hash domain while keeping the public schema-1 proof shape.

The existing single-thread bounded tar/zstd writer now supports the SDK container
manifest and one `layers/<full-sha256>.tar` entry. Manifest digest/path/size must
match registered layer custody. Approved rootfs/library descriptors stay checked;
workspace, disk templates and extra layers are excluded. Public SDK metadata
seeding preserves image environment/user and source overrides, resource/workload
metadata and layer image_size. Original budgets, artifact caps, streamed hashing,
SDK footer/checksum and final asset/source checks remain in force.

PackedExport now retains either the existing bare materialization or an opaque
container entry. The container variant keeps a strong original entry through reads,
publication and cleanup even after normal Engine value drop; fresh engines cannot
adopt it. Publication still requires the original engine, exact operator destination
and transient credential, uses the same bounded single-attempt OCI uploader and
records the same acknowledgement shape. Explicit disposal retains source accounting
until stage/helper absence is verified. No new public Port capability is enabled.

New non-VM models check retired readiness/schema boundaries; SDK sidecar/footer,
whole-file digest and archived layer byte fidelity; manifest mismatch/partial output;
original partial inode and normal reopen; replacement/link/unregistered preservation;
container registry publication/cleanup; and entry/domain retention across normal
Engine value drop. These are format, filesystem, transport and lease evidence, not
SDK helper startup, actual tar production or guest import qualification. Controller
container orchestration/sizing, whole-pipeline output credit, local/imported sources
and ordinary exact-package/platform/public-consumer gates remain pending. Crash
validation stays deferred, public exports disabled and SDK/research source unmodified.


## Export coordinator, shared output budget and explicit retained cleanup

The shared engine now provides read-only `qualify_export` and a single-attempt
`pack_export` coordinator. Actual receipt-bound source records select bare versus
container mode. Bare disks use their measured logical size to clamp the effective
artifact maximum. Containers require an explicit cached operator conversion grant,
then sequence owned SDK storage, retained launch, isolated conversion, registered
layer, original collection and packing. The Port adapter delegates the sequence
and preserves existing destination/credential/publication correlation. No new wire
operation, public result type, downstream SDK patch, CLI or server is introduced.

Fresh cached approvals return nonsecret conversion resources under the pinned
epoch. Elixir checks exact equality to the saved approved destination. Such requests
freeze upper bounds without guessing source mode; the engine allocates from actual
data. Legacy catalogs omit the grant and preserve previous source-sized request
bytes. The grant never enters caller wire requests or durable publication data.

A distinct optional shared_output_bytes budget marker leaves old fixed-budget
serialization/hash inputs unchanged. The approval hash uses a separate domain.
After private helper disks, tar and artifact share the remaining grant; the stream
has a finite cap and packing uses min(frozen artifact maximum, staging minus private
disks minus actual layer). Registered packing intent/writer reservation enforces
that cap again. Individual maxima are not simultaneous allocation promises. Older
strict budget readers reject the marker before acting on a record. No command/file
cap or implicit process-global SDK transfer override changes.

Explicit quiesced cleanup now locates only an original retained entry. Live caller
or worker leases reject before collection. It may skip SDK entry only for no
manager, or an original unstarted manager plus protected never-entered launch state.
Otherwise it collects the original manager through existing bounded controls. An
original opaque collection plus recorded runtime custody skips repeated SDK stop;
filesystem cleanup independently verifies captured retirement/absence. Lost managers
are not reconstructed on reopening. Original collection without runtime custody can
finish only its retained post-collection evidence, never replay launch or publication.

Tests cover budget tradeoffs including large tar/small pack and the reverse;
measured bare clamping; read-only missing approvals/assets/cancellation; mandatory
namespace rejection before SDK calls in a DB-only coordinator model; shared staged
output/reopen cleanup; active/foreign retained cleanup; and never-entered versus
collected-runtime observations. The Elixir contract preserves legacy requests and
rejects foreign grants/mode claims. These are models and pre-entry evidence, not
successful real helper/export/import qualification. Public admission stays disabled;
local/imported sources, ordinary platform/consumer and remaining P0-P9 gates remain
pending. Crash validation stays deferred and SDK/research sources unmodified.

## Receipt-bound imported-container input qualification

The shared engine now exposes read-only `qualify_imported_container_export` on an
already qualified stopped source. The opaque result retains that exact source
gate/job/domain and a descriptor-held sidecar/cache root. Before opening input,
the source's material receipt authenticates `source_smolmachine`; only the exact
content-addressed `artifacts` or `registry-blobs` creation-cache path is accepted.
The basename alone grants no authority. Cache/file identity, unredirected paths,
current owner, single link and 0400 mode are checked before and after bounded I/O.

One 64-KiB-buffered pass verifies both the full approved content SHA and SDK footer
CRC. The public SDK footer/manifest parser is used only after its fixed footer and
one-MiB sidecar-layout bounds. The existing bounded archive walker now optionally
inspects layers without extraction: it checks each full tar hash, the exact asset
inventory, nested tar metadata, expansion/entry ceilings and manifest order rather
than physical archive order. Logical expansion includes sparse holes; it is input
metadata, not a helper filesystem allocation proof. Cancellation/deadline checks
also wrap decoded reads and synthesized sparse holes, so compressed buffering or
hole drainage cannot hide further traversal.
Ordinary pack creation keeps its previous validation behavior.

Promotion of the original source job to its existing 12-descriptor allowance
precedes holding extra input descriptors. No second work slot or child is created.
The public metadata is inert; recheck requires the same engine and unchanged
original source/cache/file versions. No SDK cache pointer, layer-order file,
directory fallback, cache repair, host extraction or arbitrary host path is used.
Managed `Source.local/1` still selects an approved `.smolmachine`, not the SDK's
raw host-rootfs/archive source forms. Baked environment remains outside this
metadata and cannot grant workload/secret inheritance.

Private non-VM source models cover both creation caches, manifest order,
retained gate/accounting, rejected inventory edits, foreign/redirected paths,
replaced/modified/linked/mode-changed files, wrong domains and binding/lock files,
independent content/CRC/layer/inventory checks, managed manifest restrictions, cancellation and sparse
logical expansion. A decoded-reader cancellation model complements them. These
checks qualify only input handling. The integration below adds owned worker
transport/staging/budget foundations; ordinary local/registry export/import
qualification remains required. No public wire/codec/package feature is enabled. Public export admission
stays disabled, crash validation deferred and distribution approval separate.

## Imported-container conversion through original worker custody

`prepare_container_export` now retains the qualified original sidecar alongside
the held source disk. The coordinator selects this route from actual saved
`source_smolmachine`, without a caller mode flag. Original cache identity, file
version, content key and bounded ordered layer metadata enter the frozen worker
input. Before guest I/O the worker opens exactly those versions, independently
rehashes/inspects the full sidecar and compares the resulting snapshot. Parent
gate/domain/input descriptors follow actual worker collection. A second bounded
sidecar pass streams each original tar directly into guest upload messages; no
second host tar, mutable SDK cache or host layer share is allocated.

Imports mount the private source COW, but do not bind/query registry caches. Fresh
fixed `/storage/imported` paths hold extracted digest-named layers and temporary
parts for one layer. Parts stay within the SDK's fixed four-GiB file-write cap;
each request carries at most 64 KiB and each reply has a bounded control header.
Larger tars use at most 32 parts under the existing 128-GiB input ceiling. Exact
byte/hash completion and unchanged source versions precede extraction. Fixed
guest shell operations require pipeline failure detection, then remove parts
before the next layer. Any failed upload/extraction stops before flattening.
Normal helper collection/retirement owns later disk cleanup; errors do not release
or reconstruct manager authority.

The returned plan binds the original snapshot digest and saved record. Parent
verification reconstructs exact upper/lower paths, manifest precedence and empty
baked image inheritance from its held input. Actual record overrides are preserved.
Mixed source plans, changed input ordering/hash and unrelated record metadata
reject. Manifest seeding now validates its exact plan/record, so a changed record
cannot borrow earlier plan authority. The shared engine owns this behavior;
neither Port nor a future Rustler bridge performs SDK calls for it.

`ImportedConversionAllowance` binds original content SHA, total/max tar bytes,
expanded logical bytes and nested entry counts. The helper storage plan funds all
extracted layers plus one largest raw tar, 10% content headroom, 32 KiB per entry
for block/inode/xattr overhead and one GiB reserve, rounded to GiB. The existing
source COW/overlay/private allowances remain additional. A separate approval hash
binds imported/fixed/shared mode. Protected helper records rebuild the complete
plan, with exact staging ceiling, before acting. Tar and artifact still share the
remaining staging. Optional imported budget/input/plan fields are omitted for
legacy paths; strict older readers reject those fields before mutation. No new
public operation, ordinary command/file cap or credential field is introduced.

Non-VM models exercise original snapshot reopening and raw streaming, changed
input rejection before connection, multichunk uploads, upload failure fencing,
large-tar part layouts, exact plan/metadata inheritance and funded protected scratch
with mandatory SDK namespace rejection. The explicitly selected rebuilt-helper
process peer passes imported conversion with held source gates, original job
accounting, independent output/plan hashes and normal child collection. It boots
no VM. Ordinary SDK initialization/UID/mount/device behavior, actual shell/tar
mode/whiteout/xattr semantics, OS resource peaks, local/registry export/import and
full output-credit acceptance remain pending. These models do not enable public
export admission or transfer historical package/platform evidence.


## Ordinary export SDK disk initialization and failed-start custody

An opt-in Port test now accepts an exact approved package, original stopped-source
receipt and explicit storage/launch/conversion/packing phase. It opens the actual
enrolled default SDK domain with initialization disabled. SDK environment is
configured before process startup; database-only models cannot enter this path.
The original source was created/started/stopped through normal Port operations.
The pre-fix real macOS storage/COW and unstarted-manager cleanup passed. Helper
startup then failed naturally: SDK formatting copied a read-only approved template
before expanding the larger storage disk. Its original child was collected;
unmodeled SDK files prevented runtime-custody capture and cleanup. The original
owner remains retained, without forced loss, reconstructed manager or file removal.
The redacted [incomplete evidence](../docs/evidence/embedded-port-http-parity-export-sdk-macos-incomplete.json)
binds the actual package and limits these observations to those bytes.

The initializer now uses public SDK formatting at the approved one-GiB baseline,
makes only its owned disk copies writable, then grows storage through the public
SDK. It neither modifies templates nor writes SDK formatting markers. Exact
protected `storage.formatted` and `overlay.formatted` files containing `1` are
required before conversion launch configuration. Legacy unformatted batches stay
cleanable but cannot supply launch inputs.

After original enrolled-child collection, runtime custody recognizes these bounded
markers and the SDK's `agent.ready` socket. Raw disks may be shorter than their
funded maxima after a failed formatter. This permits cleanup custody only: it does
not prove launch, conversion, geometry or artifact success. Existing directory,
file-version, owner, link, role and original collection checks remain required;
unknown names still reject. Deterministic models cover these rules without SDK
lifecycle entry. Changed initializer/custody bytes need ordinary qualification.
Public export admission remains disabled and crash validation deferred.


## Fresh container and OCI disk sizing

Fresh OCI and imported/prepared container creation now allocate the one-GiB raw
baseline, finish public SDK formatting, make only the owned copies writable, and
grow storage/overlay through `VmDisk::open_or_create_at` before receipt minting.
The full requested resources are already reserved. Resulting raw sizes must equal
the saved request; missing formatting or a lower target rejects with uncertain
dispatch rather than shrinking or synthesizing markers. Existing-machine growth
still uses its separate material-transition authority. VM-mode pack seeding and
its geometry remain on the existing public SDK path.

An inert regression checks preservation of existing prefix/tail bytes and SDK
marker contents through sparse growth, rejection before growth without formatting,
idempotence and refusal to shrink. A separate explicitly ignored qualification
uses only disposable explicit disk paths and preapproved immutable account
templates. It opens no engine/domain, constructs no manager and starts no VM.
It verifies the resolver selects the approved existing plain files before SDK
formatting, then checks complete original-prefix hashes, exact sizes and unchanged
template identities/modes/content. This is an ordinary disk API witness; it cannot
qualify machine boot, guest resize, helper conversion, mounts or exports. The
explicit macOS witness passed real SDK formatting, three-GiB storage/two-GiB
overlay growth, complete original-prefix hashes, unchanged templates and removal
of only its four created files. The [scoped evidence](../docs/evidence/embedded-port-http-parity-template-growth-macos.json)
binds test binary, engine source file, input templates and private log hash.


## Staged artifact upload credit and explicit registry retry policy

Native registry clients now explicitly select `reqwest::retry::never()`. The locked
reqwest 0.12.28 source enables protocol-NACK retries by default. Native request
ceilings and single-attempt publication must count every dispatched request,
including library-level behavior. Existing bounded registry authentication steps
remain explicit; automatic transport retries grant no extra attempt. Redirect,
proxy, compression, origin, credential and deadline policies are unchanged.
Publication fixtures now use the same client constructor as production. A shared
private `bounded_attempt` applies the existing absolute deadline/cancellation
select to the production publication future and its artifact-credit witness.

The new non-VM artifact witness packs 17 MiB of incompressible private model data
through the real bounded stage/packer, then reads that greater-than-16-MiB artifact
through the production blob uploader. A loopback registry sends a valid first
PATCH response header but withholds its one-byte body. The uploader reads exactly
one MiB in four bounded 256-KiB reads and returns no further read credit before the
complete acknowledgement. Resuming it sends exact sequential ranges and verifies
the complete blob hash. API cancellation and absolute deadline expiry instead
return uncertain State without another PATCH, upload restart or blob commit.

A receipt-qualified source gate, full work metadata and staging grant remain held
through the blocked upload and its retirement. Two reserved export observers and
node health stay available; a third control request, another full source job and
concurrent same-source qualification reject. Neither cancellation nor a complete
blob acknowledgement supplies a registry publication proof. Explicit cleanup
releases only private staging, and the original source job remains held until its
lease is dropped. All fixtures close their ordinary threads/sockets normally.

This witnesses the staged-file/packer/upload/retirement boundary only. It does
not start a VM, prove real source geometry, traverse guest/worker conversion,
attest aggregate OS memory peaks or complete public export/import acceptance.
The existing SDK wire, whole-pipeline credit and ordinary platform/public gates
remain pending. No capability, protocol limit or command/file ceiling changes.


## Initial branch source/child admission

The shared engine now exposes `prepare_initial_branch` and an opaque
`PreparedInitialBranch`. This is read-only initial admission for an unbranched,
originally enrolled running source and a fresh child identity. It does not dispatch
fork preparation, reserve persistent backing, write an SDK row, mint a child
receipt or enable a backend operation. Existing guarded checkpoint preflight
establishes agent readiness and original owner/PID evidence; the source and child
then acquire the same engine machine gates in lexical name order. A partial
acquisition immediately drops its first gate. Source material, PID/birth,
root/templates and child absence are rechecked after both gates are held, so the
temporary preflight guard is never treated as continuous exclusion. No SDK source
flock is held around a future SDK operation.

The guard retains original domain/root/gates, a finite 16-descriptor work lease
and the whole existing work metadata allowance. Both reserved observers remain
available. Exact operator branch policy and profile host overhead derive the
ordinary child reservation plus the additional allowance, matching public
`Store.BranchOps`: extra memory covers guest RAM plus profile overhead; extra disk
covers twice the source disks plus rounded-up guest RAM. Extra CPU/slot declarations
retain their existing positive public policy bounds. These calculations do not
claim persistent capacity reservation or measured CoW savings. Six shared cases
are consumed by both Rust and actual public Elixir admission, including exact
capacity and one-unit-short rejection in each resource dimension.

A separate request digest binds original source receipt, fresh child intent,
operation/hold/idleness, exact policy/plan, SDK revision, original source PID/birth,
owner epoch and the fixed shared-RAM strategy. Rechecks reject another domain
owner, epoch, changed material or child presence. Legacy receipts, foreign/stopped
sources, nested/held/remote/networked/container/injected profiles and insufficient
policies do not become fork permission. `idle: true` remains a host assertion;
these checks do not attest guest process idleness or absence of RAM secrets.

The locked SDK selects shared materialized RAM for unset/auto/shared
`SMOLVM_BRANCH_RAM_MODE`; explicit paged mode uses a guardian manifest and may
create an extra raw-forked guardian. Initial admission reads this setting without
mutating it and rejects paged/unknown values. Future owned SDK dispatch must freeze
the shared selection and qualify the exact libkrun/shared-generation behavior;
a post-fork PID manifest cannot establish enrollment. SDK fork preparation also
copies source labels into the child and can update the Linux source's
`fork_lineage_pid_start_time`. Child ownership replacement and a distinct source
material transition are mandatory before either can be accepted. Held activation
must remain tied to one durable release intent, never a new call after uncertainty.

Six branch units and the paired-gate model cover policy/hash/eligibility,
pre-dispatch rejection, control isolation, stable lock acquisition and rollback.
They create no VM and establish no positive live-source qualification. Durable
source/child intents and backing reservations, existing-child source handling,
child enrollment/identity reset/held release, bridge/store histories and ordinary
independence/cleanup qualification remain pending. Full P8 branch scope is intact;
public native branch support remains disabled.


### Protected initial branch intent

`PreparedInitialBranch.persist_intent` consumes the original admitted guard and
writes one prepared-only source/child declaration into the protected material
journal. `PreparedBranchIntent` retains the original gates, source root, domain
and bounded job. Its recheck matches the exact stored declaration and original
owner epoch/source PID authority, checks current source material and verifies
child absence. No serialized declaration can construct that opaque handle.

Journal validation binds the whole source receipt, child ownership intent,
operation/hold/idleness, exact policy/resource plan, PID/birth, owner epoch,
SDK/shared-RAM request digest and preceding material head. It excludes concurrent
growth/capture intent, completed operation-ID reuse and exhausted histories.
Generic record verification then fences lifecycle, execution and receipt-bound
inspection; passive inventory and both reserved observers remain available.
Normal reopening does not erase or adopt the declaration. Optional omission
preserves unbranched journal bytes and readers reject unknown entered phases.

Explicit `abort` requires the retained original handle plus unchanged source,
root, owner and child absence. A separate cleanup budget can outlive cancelled
admission; it grants no fork entry. Abort now records a separate protected retirement
before acknowledgement; the source receipt and ordered material chain remain
unchanged. Dropping a handle does not abort. Explicit prepared-only retirement
and read-only result lookup are described below.

Four new deterministic models cover journal reopen/fencing, changed identities/
plans/source configuration/PID/lineage, mutually exclusive operations, historical
ID reuse, exact abort and actual engine lifecycle/command rejection before SDK
entry. Their synthetic process facts never establish positive enrollment. This
is a pre-dispatch declaration, not persistent resource acquisition, SDK fork
preparation, child authority, hold/release or live/platform qualification. Those
remaining P8.4 gates and public capability exclusion stay unchanged.


### Durable prepared-branch retirement

`InitialBranchRetirement` is a distinct correlated result from either original-
guard abort or explicit `retire_prepared_initial_branch`. Its domain-separated
digest binds the entire original declaration, including source/child authority,
resource plan, PID/birth, owner epoch and request hash. It grants no child receipt,
material transition, SDK entry, child-disposal or backing-release authority.
Serialized hashes alone cannot establish ownership: callers must use the exact
result returned from the protected source journal.

Explicit retirement requires caller quiescence, current domain/root/marker,
lexically ordered source/child gates, the unchanged prepared-only declaration and
source material, verified child absence and opaque source authority. A running
source must still be originally enrolled in this engine. A stopped source must
have no current native handle/PID and positive absence of its original PID/birth.
A stopped SDK row alone is insufficient. Normal opening never invokes retirement.
The original declaration cannot represent entered SDK dispatch; future fork
entry must add distinct protected state before any mutation.

The completed receipt is synchronized with intent removal before acknowledgement.
`inspect_initial_branch_retirement` only reads that protected result. An explicit
retirement retry returns an existing exact receipt before gates/current source or
child checks, without writing or replaying the operation. Wrong request/source
correlation rejects. None is not absence, disposal, cleanup or capacity authority.
Retirement records anchor their original material head in the actual ordered
history and cannot be relabelled onto a newer receipt. Their revisions are
nondecreasing; operation IDs are unique across growth/capture/retirement. Total
operation records remain bounded at 1024, and preparation reserves room for its
own retirement. Existing records omit the optional retirement collection.

Explicit retirement and read-only lookup each reserve the full material-control
metadata allowance and eight descriptors for retained root, SQLite/actor readers
and journal publication. Original-guard abort uses its retained work admission.
Explicit retirement consumes one control slot and leaves the other available when admitted;
full control admission rejects without changing intent. The model holds the full
branch work allowance and an observer while retiring, then checks unchanged
remaining admission. Typed receipts, normal value drop/reopen and ignored-result
models verify lookup without another write. They launch or terminate no VMM and
provide no ordinary fork/platform qualification. The public Port branch capability,
bridge/store retirement histories and remaining P8.4 implementation stay pending.


### Retained material publication (October 15, 2026)

The current private engine path retains the original SDK runtime, ordered gates,
metadata/result spools and bounded preparation backing through entered work and
normal worker collection. Its distinct protected entered grant permits one
held-fork preparation. The parent verifies original spools, bounded SDK rows,
snapshot identity and original source enrollment. Neither collection nor caller
retirement releases ownership or backing.

`RetainedBranchPreparation.publish_material` now records an exact publication
plan before changing child identity. It derives independent owner/incarnation
labels and a source/intent/raw-child/generation digest; copied labels confer no
ownership. Atomic no-replacement marker publication and a bound child root journal
precede the distinct source material transition. Completion checks those actual
files plus original running source authority. The source creation fingerprint
stays fixed, while the ordered branch proof advances even when macOS source
material is unchanged. Source/child gates, snapshot, runtime and backing remain
retained. A material receipt does not establish child boot, readiness or release.

Exact protected result lookup handles lost acknowledgement without SDK replay or
another journal write. Mixed histories reject operation reuse, reordering and
broken immutable/head linkage. New private journal fields are omitted on ordinary
unbranched records; strict older readers reject new branch state. Four private
non-VM row/file models exercise these boundaries with synthetic prior-authority
facts. They run no VMM or live persistence interruption and establish no ordinary
SDK/platform qualification. Public codecs, bridge/store histories and persistent
dual reservation, entered resolution, child boot/enrollment, existing-child
sources, held release and ordinary acceptance remain required. Public branch
capability admission stays disabled; crash validation stays deferred.


### Explicit held-child first boot

`RetainedBranchPreparation::boot_child` uses the original published child,
retained source/snapshot roots, runtime, gates and backing under the original
absolute budget. It requires the actual approved SDK namespace and live original
source enrollment. Public existing-disk constructors and
`AgentManager::start_with_full_config` select the exact snapshot, source UID share
and parent watch. No SDK convenience fork, cold fallback, second runtime, implicit
release or retry is used. The package-approved agent rootfs must match the already
selected launcher environment. Receipt-bound bare sidecars are rehashed, manifest
checked and pinned before public packed-layer configuration; actual disk geometry
may legitimately exceed the original bare manifest after approved growth.

A protected first-boot journal synchronizes entry before SDK launch and records
original epoch enrollment after return. The retained manager survives cancellation
and uncertain observation. A historical boot identity grants neither current
liveness nor guest identity initialization. Ordinary restart rejects an unfinished
branch origin instead of interpreting inherited checkpoint labels as a new restore
or using the ordinary SDK cold-start path. The initialized reader is reserved;
its production writer, guest identity reset and explicit held release are pending.

Branch admission reserves 24 work descriptors and two child slots for the whole
preparation/boot/identity sequence within unchanged global caps, preserving eight
control descriptors and both observers. Seven private non-VM models cover explicit
configuration, root/input substitution, epoch mismatch, no replay and protected
journal phases. Actual SDK boot semantics, manager transfer to ordinary lifecycle
ownership, initialization/release, public integration and platform qualification
remain required. No branch capability or acceptance row is enabled by this work.


### Bounded original-child guest initialization

`RetainedBranchPreparation::initialize_child` consumes only the original booted
manager and opaque epoch enrollment. The child must still be the exact running
held record and the continuing source must retain its original enrollment.
Before guest IO, a protected first-boot transition binds the fixed bare-guest
program digest, original boot intent/PID/birth, fresh challenge and host clock
policy. Public SDK `AgentClient::vm_exec` runs only that engine program, with
separate validated positional arguments and no caller command or environment.
The program renews bare-guest hostname, disk machine identity, existing SSH host
keys and cloud-init instance state, stirs the guest random stream, marks the
public SDK restored forkpoint and attempts Linux guest wall-time correction; only
the specific fail-soft clock warning is accepted.
It does not release the parked helper or scrub arbitrary inherited RAM; the
original approved idle/bare-source assertion remains necessary.

The ordinary bounded agent relay rejects reply headers before SDK allocation.
A short private temporary relay endpoint supports long owner-domain paths without
changing process CWD or redirecting SDK state. An absolute deadline/cancellation
guard shuts down only this exchange's socket;
SDK failure, mismatched confirmation and uncertain completion cannot replay
initialization. Only exact exit-zero challenge confirmation advances IdentityReady.
The original manager/runtime/gates/backing remain retained. IdentityReady is
neither a held-release proof nor ordinary cold-restart authority. Seven private
models exercise fixed program/argument/identity binding, confirmation, actual
public SDK exchange against a synthetic agent, oversized response headers,
deadline/cancel, unchanged source/child rows and journal no-replay/origin checks. They execute no guest program.
Actual guest semantics, initialization/release qualification, public integration
and manager handoff remain pending; no branch capability is advertised.


### Original-job typed release and child material

`RetainedBranchPreparation::release_child` retains the original branch admission,
manager, source/child gates, runtime and backing. A `BranchReleaseRequest` binds
its caller's operation/request identity. Protected first-boot and material entry
records bind the original publication, opaque boot enrollment, initialization
digest and one release mode before guest entry. The shared bounded owner-process
agent exchange now serves initialization and release, including its short private
relay endpoint and absolute deadline/cancellation guard.

For initial non-held creation, a public SDK BranchpointRelease request with empty
environment preserves inherited-helper acknowledgement and no-boundary cleanup.
Explicit held release uses public BranchpointActivate with exact standard bare
paths, empty parameter files and one fresh activation token. Both require the
public typed-branchpoint capability. Explicit activation requires the exact
`already_done: false` response, while initial release requires its distinct empty
acknowledgement. Missing data, duplicate activation, typed failures, oversized
headers or uncertain observation cannot supply a release proof or cause retry.
This avoids the SDK convenience function's automatic reconnect/retry behavior.
It does not infer workload readiness from the acknowledgement.

After exact confirmation, unchanged source/child rows and original live process
identities precede a full-row CAS changing only forkpoint_held. A distinct child
release proof preserves the immutable creation fingerprint. A branch-bound leaf
journal records only that one permitted release material transition, keeping old
unbranched bytes unchanged; unsupported child capture/growth histories cannot be
smuggled into this transition. Both synchronized material and first-boot
completions precede restart authority. The earlier reserved Initialized parser
shape grants no restart. Exact completed-result lookup is read-only, uses the
original opaque enrollment and never repeats guest IO, even after the original
budget expires. A changed held flag or one completed journal is insufficient.

Seven private models cover exact before/after material, both public SDK requests,
malformed/duplicate confirmations, capability/header/cancellation failure,
entered no-replay, synchronized publication/result lookup and history corruption/
legacy omission. They start no VM or guest program. This native path still uses
the original creation job; later public held release needs separate fresh store/
version admission after manager handoff. Held-creation finalization, ordinary
manager lifecycle ownership, entered resolution, public proof/codecs/store
integration and ordinary SDK/platform qualification remain pending. Public native
branch admission stays disabled; crash validation remains deferred.


### Original manager handoff and retained backing

`RetainedBranchPreparation::finish_child` requires completed original work and
actual original source/child enrollment. It verifies the exact final material,
unique retained ownership, collected IPC and absence of a live host worker before
installing the same Arc<AgentManager> into the shared direct-manager cache.
Opaque boot enrollment, the original source SDK runtime and domain follow it;
there is no inventory adoption or second manager/runtime. A distinct HeldReady
journal phase completes original held initialization without releasing the helper
or granting cold restart. Released children retain the exact release receipt.
Normal held commands and start/stop reject. Direct-manager foreground commands
route through the bounded owned worker path instead of SDK reconnection.

After manager installation, preparation roots and paired gates close. Atomic
accounting retirement frees only temporary work/parser/FD/launch/IPC allowances.
The original backing charge follows a distinct retained lease. Completed result
and owner context have 128-KiB per-child bookkeeping under a separate finite
128-MiB pool, leaving the existing 128-MiB SDK-parser allowance and both observers
available. Completed original-token lookup is read-only and never boots or repeats
preparation. Registry teardown quarantines and retains completed backing/context
rather than asserting source disposal. Public backing/dependency retirement and
replacement enrollment are still required; lease teardown alone grants neither.
These private persistent limits need explicit negotiation before public activation.

A continuing-source observation additionally requires original enrolled source
PID/birth/runtime and exact protected current material for every SDK dependency.
Published labels alone or an unrecorded held-flag change cannot override frozen/
unknown dependency state. Children are checked one at a time through bounded
read-only rows. Ordinary lifecycle dependency exclusion remains unchanged.

Seven private non-VM models cover temporary-versus-retained accounting, subsequent
work/control capacity, rejected unfunded/quarantined handoff, held completion and
restrictions, missing release, prepared-token rejection, and metadata-only source
candidacy against altered/unpublished children. They prove no real manager handoff,
source commands or cold restart. Ordinary SDK/platform qualification, later
fresh-budget held release/deletion, multiple-child sources, backing retirement/
replacement and public proof/store/codec integration remain pending. Public branch
admission is disabled; crash validation remains deferred.

### Fresh-budget held release after manager handoff

`Engine::release_held_branch` uses the original completed context and opaque boot
enrollment. Receipts/rows alone cannot construct them. A new absolute budget funds
one work slot, 20 descriptors and 32 MiB temporary metadata. An additional 128-KiB
result-history lease comes from the bounded persistent metadata pool before
dispatch; existing disk backing is not charged twice. Ordered source/child gates
and the child's SDK source lease remain retained through actual host-worker return.

Admission checks the current protected source head, original source PID/birth and
every bounded SDK dependency against protected current child material. It does
not reuse the creation request's expired deadline or frozen old source head.
The original-job and later paths share the same bounded typed SDK exchange,
unchanged-row checks, held-flag-only CAS and synchronized material/first-boot
completion. Original manager and epoch checks fence both paths.

Entered uncertainty keeps work/gates/SDK lease and history metadata; another call
cannot replay activation. Exact completed lookup can recover an acknowledged
result without SDK dispatch, including after ordinary cache removal. Only an
existing exact tracked child receipt is promoted before temporary leases retire;
lookup never re-enrolls stopped/deleted children or overwrites another incarnation.
Persistent backing and result metadata remain charged. Seven private non-VM
models exercise these boundaries; no real SDK branch is qualified. Public
store/version/protocol routing, deletion/retirement, replacement, multiple-child
creation and ordinary platform acceptance remain pending. Public native branch
admission stays disabled and crash validation remains deferred.

### Branch source admission with existing leaves

`Engine::branch_preflight` separates branch source qualification from portable
capture. It checks bounded current source/dependency records, exact protected
head, original enrolled source PID/birth/runtime and nonpending checkpoint
lifecycle before probing the agent through the existing header-first relay.
One original absolute budget covers the probe and post-probe authority recheck.
Its work allowance reserves 20 descriptors, 32 MiB metadata and no child slot;
control observers remain separate. This does not assert guest idleness.

Previously published leaves are checked against their independent creation
bindings, markers and current protected child material, one bounded row at a
time. A protected prepared declaration permits no existing row for its new child;
only its exact entered grant can exempt that unpublished child. It cannot exempt
another name, an unknown sibling, duplicate names or an unrelated pending source
operation. After publication the new leaf needs the same complete proof as its
siblings. These checks follow SDK worker preflight under the source lock,
collection, source/child publication, boot, initialization, release and handoff.
Prepared-only retirement uses the same sibling checks without deleting leaves.
Capture and ordinary source lifecycle operations still reject dependencies.

Four private non-VM models cover successive source publications and unchanged
earlier child material, wrong/pending/exempt children, unknown siblings,
cancellation without journal rewriting and missing original source enrollment.
They establish no live fork, isolation, cleanup or platform qualification. Public
proof/store/protocol/dual-reservation integration and actual SDK multiple-child
qualification remain required; public branch admission stays disabled. Backing
retirement/replacement is still pending and crash validation remains deferred.


### Explicit deletion of an original completed held child

The native delete path routes a retained original held child to
`Engine::delete_held_branch`. Ordinary held stop/start remain forbidden. Matching
rows or saved receipts cannot reconstruct the original manager, opaque enrollment
or domain/runtime context. Ordered source/child gates, an SDK child lease, one
work slot, 24 descriptors, 32 MiB work metadata and the existing 128-MiB SDK-parser
allowance precede entry. Another 128 KiB of persistent result bookkeeping is
funded before dispatch; existing disk backing is not charged twice.

A bounded 0600 domain record binds the original plan, child/process/boot identities,
initialization digest and nonce. It lives outside the SDK child directory and
records Collecting, Collected, Deleting and Deleted. Only the original opaque
BootCollection proof permits collection publication and the stopped-row CAS. SDK
stop return alone or a stopped inventory row supplies no collection authority.
The actor pending record excludes sibling actor reaping during the actual normal
SDK stop call. A previously normally exited original child can be collected
without sending a shutdown request. No manager is reconstructed from PID files.

After collection, the original SDK lease closes before Runtime deletion takes its
own source lock. SmolBox gates and whole-job allowance remain held. Runtime deletion
can see only the verified stopped held row; it does not select unreachable recovery
or another boot. A fresh original collection check plus bounded SDK row/reservation
and child-directory absence permits Deleted. Only then can exact original cache
entries and transient gates/work retire. Original context, source backing and
result bookkeeping remain charged for separate dependency/backing retirement.

Unknown collection/deletion cannot replay or release its leases. A completed exact
result is read without another SDK call or journal rewrite. Five private non-VM
models cover phase ordering, required absence, no original-manager reconstruction,
unknown admission retention/control headroom, exact historical lookup and record
identity/mode/link/version protections. They run no guest shutdown or SDK delete.
Public/store/protocol activation, pre-handoff child disposal, explicit unknown
delete resolution, dependency/backing retirement, replacement and ordinary SDK/
platform qualification remain required. Public branch admission stays disabled;
crash validation and distribution approval remain separate.


### Explicit original held-delete absence resolution

`Engine::resolve_held_branch_deletion` requires a valid operation/request digest
and explicit caller quiescence. The bridge must fence its previous durable and
controller requests. The native path additionally requires the original retained
context/gates, actual host-worker return and exact opaque child/epoch collection.
It performs no SDK stop, delete, reconnect, boot or material mutation. A live or
unreturned actor, missing original context, remaining SDK row/reservation or child
directory cannot supply absence. Pending actor dispatches still fence collection.

Complete original-child absence during Collecting, Collected or Deleting records
a distinct ResolvedAbsent proof. It confirms disposition without claiming SDK
deletion success. The proof binds the child, original deletion-intent digest,
resolution operation and caller request. Exact retries read the same result; a
different operation/request rejects. Known SDK Deleted cannot be converted into
a resolution result. Recorded lookup needs no current SDK inventory and never
rewrites the journal. Completion retains its kind in the original owner cache.

Existing schema-one records keep their exact absent optional field and 64-KiB
limit on both read and write. Only schema two with ResolvedAbsent and its exact
proof is accepted at the 80-KiB limit, allowing bounded additional request/proof
bytes even for an accepted legacy intent. Unsupported schema/phase/proof pairings
reject. These internal reader/limit changes still need public package, protocol
and store negotiation before capability activation.

The resolver uses the existing reserved material-control allowance: four
descriptors and 32 MiB independent metadata, no work or child slot. It admits
while the old deletion retains its work/parser allowance and the pool is
quarantined; one ordinary control observer can coexist. The original work/gates
stay retained through proof publication and exact original cache retirement.
Only transient admission closes afterward. Source backing and persistent
bookkeeping stay charged, and resolving this child never clears wider quarantine.

Five additional private non-VM models cover quiescence/original-context rejection,
all entered deletion phases, active workers, remaining material, foreign
collection, cancellation, typed histories, proof/schema corruption, bounded legacy
compatibility and quarantined control accounting. They establish no actual SDK
shutdown/deletion or live resolution qualification. Public/version/store routing,
collected residual-child cleanup, pre-handoff disposal, dependency/backing
retirement/replacement and ordinary platform acceptance remain pending. Public
branch admission remains disabled; crash qualification stays deferred.


### Continue a collected child's unentered deletion step

`Engine::continue_held_branch_deletion` requires explicit caller fencing, a valid
operation/request, the original returned host worker, retained gates/work and
positive original epoch collection. It verifies the same manager identity and
exact held material. A collected original child can have its stale Running row
normalized to Stopped through a full-row CAS; different process identities,
changed material and foreign collection reject. This never repeats shutdown.
Cleanup uses the original collection epoch even when launch admission is fenced;
pending actors still exclude collection and no boot authority is granted.

Schema three records a frozen continuation request in Finishing before the row
update and final deletion. Only that same unentered Finishing request can
continue with a fresh cleanup budget. Deleting cannot move backward or invoke
SDK deletion again. Earlier schema-one/two records omit the new field exactly
and keep their existing limits. Schema three uses the existing 80-KiB expanded
record bound and accepts only the declared continuation/phase/proof combinations.
A later absence resolution preserves and hashes the continuation binding and
cannot become a successful continuation result. Private schema changes still
need public package/store/protocol negotiation before capability activation.

Ordinary and continued deletion now share final stopped-material checks, original
collection, SDK source-lock closure, protected one-shot entry and positive
row/reservation/directory absence. The SDK callback is invoked only after Deleting
publication and a budget recheck. SmolBox gates stay held; the outer SDK lock
closes before Runtime acquires its own. An entered/failed SDK delete retains its
allowances and requires positive absence resolution, not retry.

The old work slot, 24-descriptor/32-MiB work allowance and 128-MiB SDK-parser
allowance fund the final SDK step. A four-descriptor/32-MiB material-control
request follows actual owner-thread return, leaving one ordinary observer
admissible during quarantine. No new work/child slot or disk backing is reserved.
Only exact cache retirement and acknowledged completion retire transient work.
Backing, persistent metadata and any wider quarantine remain.

Eight private non-VM models exercise original authority, row normalization, frozen
requests, record compatibility, lock closure/gates, one-shot callback entry,
uncertain no-replay, separate absence resolution, fresh budgets and retained
accounting. Their SDK results are private row/file callbacks; no SDK deletion or
guest shutdown ran. Public continuation/version/store/protocol integration,
pre-handoff disposal, partial/unproved residual cleanup, backing retirement/
replacement and ordinary platform qualification remain pending. Public branch
admission stays disabled and crash validation remains deferred.

Final entry additionally requires fresh bounded dependency inventory and the
pinned fork child's absent-or-linked `pack` cache. The SDK skips volume detach
for those shapes. A private directory rejects before SDK entry; it cannot launch
an unadmitted detach utility or detach a source/sibling volume. Private callback
models verify the guard and preserve a linked source marker.


### Residual directory cleanup after collected held-child deletion

`Engine::cleanup_held_branch_deletion` requires explicit caller fencing, the
original retained context, returned host worker, exact manager identity and opaque
original epoch collection. SDK row and creation-reservation absence precede any
unlink. Original directory identity is pinned by an actual descriptor retained
across SDK deletion until acknowledgement; missing/replaced roots cannot create
cleanup authority. The cache must still have the pinned SDK's absent-or-linked
shape. This operation never calls SDK deletion or shutdown and grants no boot.

A separate protected 80-KiB-bounded residual record binds the original intent,
optional deletion continuation, cleanup request and parent directory identity.
Cleaning precedes the first unlink. Descriptor-relative removal uses the existing
one-million-entry and 4096-byte ancestor-path bounds, rejects device crossings and
does not follow source-cache links. Root/parent synchronization, fresh original
collection and complete row/reservation/directory absence precede the primary
resolved-absence proof and residual Cleaned record. This cannot claim SDK success.
Primary schema-one/two/three shapes and limits remain unchanged.

Only the frozen request can continue partial Cleaning with a fresh budget.
Known removed roots can complete forward; unknown absence cannot establish an
initial cleanup grant. If the primary proof was already acknowledged, the exact
saved request can close out only the cleanup audit, without inspecting/removing
new material. A different request cannot supersede partial cleanup via generic
absence resolution. Protected-file validation and version checks cover both
namespaces independently.

Traversal uses the original retained 24-descriptor work reservation. One extra
four-descriptor/32-MiB material-control job leaves an ordinary observer admissible
while quarantined; it follows actual worker return. Original gates/work/parser
allowance retire only after exact cache acknowledgement. Source backing,
persistent history and wider quarantine remain. Eight private row/file/counter
models cover partial cleanup, caller fencing, foreign collection, substituted
roots, row/reservation exclusion, links/siblings, accounting, record namespaces
and audit-only completion. They run no VMM, SDK deletion or live fault campaign.
Public bridge/version/store integration, released/restarted children, pre-handoff
disposal, backing retirement/replacement and ordinary platform qualification
remain required. Public branch admission stays disabled; crash validation remains
deferred.


### Explicit native branch backing-accounting release

`Engine::release_branch_backing` requires both caller quiescence and the same
positive host backing-removal confirmation required by public HTTP storage
release. Native path checks additionally require absent source and child SDK
rows, creation reservations and original directories. It does not remove files,
run generation GC, invoke SDK lifecycle APIs or retire source dependencies.
The host assertion still covers material moved outside the expected namespace;
path absence alone is not proof that every original backing file was removed.

Only the original completed registry context can select the actual backing lease.
Ordered source/child gates, original epoch binding, source quiescence and original
source process absence plus opaque original child collection precede a fresh
release. Runtime PID caches must be empty. The original child manager is marked
stopped only after collection; no signal is sent. Prepared/entered/uncompleted
branches cannot substitute inventory or caller-created proof for that context.

A separate protected 80-KiB-bounded record binds original completion, boot/child
identity, plan and initialized identity digest to a typed BranchBackingRelease.
Its public digest binds publication, operation/request and exact native charge.
The file is account-owned, single-link, 0600, no-follow, bounded and inode/version
checked, atomically published without replacement and synchronized before native
material accounting changes. Exact known result acknowledges only the same
request, re-synchronizes the domain and never requalifies/removes new material.
A failed publication or cancelled acknowledgement retains the charge; an exact
known proof permits subsequent explicit acknowledgement without a second release.

One four-descriptor/32-MiB material-control job and both gates follow actual owner
thread return, including observer timeout. One ordinary observer remains
admissible under quarantine. Material bytes alone become free: persistent result
metadata/history, sibling backing and wider quarantine remain. Completed zero-
material entries can drop normally on registry shutdown; unresolved entries still
retain/quarantine their original owner and charge. Seven private row/file/counter
models cover these boundaries without VMs, SDK cleanup or live interruption.
Public branch retirement/storage-release protocol, durable dual accounting,
reader/package negotiation, replacement and ordinary platform acceptance remain
required. Public branch admission is disabled; crash validation stays deferred.


### Scoped public branch coordination

Automatic branch preflight/create/completion/release now assign source and child
backend references independently to their saved records. They retain the worker
pin already selected before durable dispatch intent. Source identity never stands
in for the child's context. Explicit public resolve/retire/storage-release now
use the existing NativeResolution/NativeAuthority path: one owner/epoch pin,
helper quiescence and worker lease precede observations; the authority fence
survives the fresh parent claim and final guarded store transaction.

BranchObservation preserves one pin across source/child queries. A changed
registration cannot retarget the second query; an unavailable pin stays
unavailable. Deleted resolution alone permits source not-found. Retirement checks
only the child; storage release requires both absent. The HTTP adapter continues
to use its original client, result semantics and atomic branch store operations.

Seven semantic transport models exercise record scopes, preserved budgets,
missing/present/uncertain observations and replacement/unavailable pins. Four
public/store models exercise quiescence, the held authority fence through final
writes, busy/stale/competing authority rejection and conservative public backing
accounting. These models use validated public branch records and semantic native
channel adapters. They do not enroll native assignments, invoke SDK actions,
qualify native branch material proofs or run a live fault campaign. Native branch
Port requests, durable authority/codec histories, engine backing-release proof
acknowledgement and ordinary SDK/platform acceptance remain required. Public
branch admission remains disabled; crash validation stays deferred.


### Port source-only branch preflight

Protocol two now carries BranchPreflight with exactly a saved material receipt
and a maximum 30-second absolute budget. Session admission requires the branches
feature version and matching target/domain; the legacy path cannot dispatch it.
The helper adapter calls only Engine.branch_preflight, which retains original
source enrollment/material/gates, bounded dependency checks and a bounded agent
ping. This is neither a fork nor guest-idleness/readiness proof for a future child.

The helper routes this probe through work admission, preserving the reserved
observation/control lane. Replies require zero output, Running state, PID/birth,
resources and explicit offline/unmapped/unmounted configuration. Streams and
qualification/creation outcomes reject. Scoped branch_source construction binds
the caller's saved assignment/current identity; reply decoding preserves that
receipt and checks source resources/configuration instead of adopting inventory.
Both public adapter and Port feature gates reject currently approved packages.
No capability declaration, SDK source or public native admission is enabled.

A shared synthetic transport fixture, three Rust protocol contracts, one semantic
helper peer and four Elixir contracts cover exact shapes, material/domain/feature
fences, bounded budgets, credited stream rejection, source reply/resource
correlation and current-package rejection. They run no SDK action or live source
qualification. Remaining branch requests, creation Port workflow routing,
durable branch authority/history/codec and dual reservations, package negotiation,
replacement and ordinary platform acceptance remain required. Crash validation
stays deferred.


### Shared-engine original branch creation workflow

Engine.create_branch consumes a BranchCreateRequest with exact source receipt,
independent child intent, operator-selected approval and optional initial release.
Held requests require no initial activation. Non-held requests require a valid
activation operation/request distinct from the creation operation before any
admission. The caller must retain the public durable child-plus-extra reservation;
internal preparation backing does not replace public capacity accounting.

The driver composes the existing guarded stages: protected initial intent,
retained preparation worker, material publication/first boot/guest initialization,
optional initial release and original manager handoff. One caller ReadBudget
follows every stage. No convenience fork, cold fallback, new SDK owner or replay
of an entered step is introduced. Post-intent errors remain uncertain; pending
journals/original gates and retained workers/backing keep their existing fences.

Engine.inspect_branch_completion reads only the original completed registry and
returns historical creation evidence. It compares the exact prior source material
head, complete child identity/mode, approval and initial activation. Duplicate or
conflicting results reject. None means no original completed result, not verified
child absence, replay permission or free capacity. Later child release/deletion
cannot rewrite that original creation kind. No current SDK rows or PID labels
reconstruct ownership. A four-descriptor/32-MiB material-control allowance bounds
lookup while quarantine and old work/backing stay retained; history is unchanged.

Six private non-VM models exercise mode/activation admission, held/initial-release
result correlation, changed source/child/policy/activation, corrupt/duplicate
results, cancellation, original-owner rejection and quarantined accounting. They
construct typed result models without constructing an SDK manager or dispatching
a fork. Happy-path SDK workflow/platform qualification, branch Port DTO/catalog
routing, public durable proof/codec/dual reservations and replacement remain
required. Public native branch admission stays disabled; crash validation remains
deferred.


### Branch creation and historical completion Port contracts

Protocol two now carries create_branch and inspect_branch_completion through the
helper's typed adapter to the original shared-engine workflow. Each request fixes
the source receipt, independent child intent, full resource/backing approval and
optional distinct initial activation. Feature negotiation and exact immutable
operator catalog equality gate admission and dispatch; matching an approval ID
alone is insufficient. Absent catalogs preserve legacy configuration bytes and
reject branch work. Present catalogs are major-two-only and bounded to 32 policy
IDs with at most 32 distinct approved profile overheads each. All variants of an
ID must have identical backing resources; exact duplicates reject. Creation uses
work; historical lookup uses observation admission. Branch-bearing configurations
have a finite 512-KiB allowance for the full profile catalog; configurations
without that catalog retain 64 KiB. Both the writer and helper reader enforce it.

Typed publication, child origin and initial-release proofs retain the engine's
canonical hash algebra and require exact request/platform correlation. Lookup
None is not child absence, replay permission or free capacity. All results reject
streamed bytes. Completion proofs are capped at 64 KiB; branch terminal envelopes
receive 68 KiB of bounded control storage. Ordinary controls keep their 4-KiB cap;
the event allowance is unchanged. Combined queue storage is finite at the prior
event allowance plus 65 branch control allowances. Stalled-event/control tests
preserve two observer replies and reject overflow before sequence advancement.

Synthetic held/released fixtures validate unchanged in engine and protocol. Three
protocol contracts, an adapter fixture, catalog/helper peers and one stalled-output
contract add no live SDK qualification. Elixir readers and catalog forwarding now
check the same canonical hashes, exact request/domain/platform and distinct
creation/lookup results. Approved source profiles determine host overhead; the
worker allocation floor cannot substitute. Current packages reject both operations
before native dispatch even with an exact catalog. Durable branch authority/
history/codec/dual reservations, public backend routing, backing acknowledgement,
pre-handoff disposal, released/restarted deletion, replacement and ordinary
end-to-end platform acceptance remain required. Public branch admission stays
disabled; Rustler and Kubernetes implementation remain future work, and crash
validation stays deferred.


### Branch material-history and selective persistence readers

BranchPublication and BranchReleaseTransition now have typed Elixir forms with
redacted inspection, preserving the existing wire/hash algebra. MaterialHistory
checks exact prior receipts, unique operation IDs and known growth/capture hashes,
checkpoint heads, platform/lineage continuity and backing disk totals while mixing
source branches with growth, capture and capture resolution. A known absent head
or lineage is never an unobserved wildcard. Branch publication may advance a
revision without changing record bytes. Child release is its own root-linked
sealed history, consistent with the current engine journal's one-release-only
rule. Neither typed link grants runtime enrollment or guest readiness.

Identities with branch links require their complete chain. Branch histories share
the native 1,024-link ceiling; existing branchless histories retain 288. Two
synthetic macOS/Linux fixtures pass every prefix through the actual engine journal
and Elixir reader without an SDK manager, disk mutation or VM. Individually valid
crossed hashes/heads, missing/reordered links, duplicate operation IDs, platform/
lineage mismatch and extra child-release mutation reject.

Attached command evidence carrying these typed links selectively uses v29.
Older-envelope substitution, compression, trailing bytes, missing history and a
v29 envelope without branch links reject. Existing records keep their earlier
encodings. This codec foundation advertises no native_branch_histories capability
and enables no public branch operation. Durable branch intent/completion authority,
prepared retirement, atomic source/child histories and dual reservations, store
replacement and ordinary source/platform qualification remain required. Crash
validation remains deferred.

### Held-release checked dispatch and completed-result qualification

The shared engine now exposes release_held_branch_checked with the original held
BranchCompletion, frozen current source receipt and distinct BranchReleaseRequest.
It validates the exact retained publication, initialized identity and immutable
source origin before entering the existing fresh-budget release workflow. A
receipt, SDK row or syntactically valid different completion cannot manufacture
that original context. The lower release workflow still requires its original
manager/enrollment and ordered source/child gates before SDK entry.

qualify_held_branch_release uses reserved material-control admission and the same
original context. It never invokes the SDK or reconstructs a manager from inventory.
An active original worker or incomplete protected result remains uncertain. Both
recorded completions plus collected original work may promote only an already
owned handle and retire transient work/gates. A stopped/deleted missing handle is
not re-enrolled. Backing stays retained. This qualification is historical result
recovery, not a positive current source/child observation; None establishes neither
absence nor permission to replay an uncertain attempt.

Protocol two carries release_held_branch and qualify_held_branch_release with the
full original held completion, current source receipt and exact release request.
The nested original approval must equal an immutable helper catalog entry before
native dispatch. The checked engine entry independently compares that completion
with original retained authority. Creation/initial activation cannot substitute for
explicit release. Requests have a finite 68-KiB bound and distinct 900-second work/
30-second qualification ceilings. Both require branches:1; current packages do
not activate that feature. Qualification uses reserved observation/control rather
than work, including during quarantined admission.

held_branch_released requires an explicit transition. held_branch_release_presence
requires a present nullable transition field; missing proof cannot become success.
Both reject streams and correlate original binding/identity, request, source/child
namespace and package platform. All branch proof terminals use the existing finite
68-KiB branch control allowance, even when the proof is small; ordinary control
routing rejects them. Queue/event limits and the two ordinary observer slots stay
unchanged. Elixir validates the same envelope and constructs it from the original
frozen store release without issuing a replacement request.

Two new engine models validate exact completion/context rejection and shared
synthetic macOS/Linux hashes. Three protocol models, helper catalog/lane and bounded
output models, and four Elixir models cover these contracts without a VM. Existing
held-release models retain the two-completion/collection/cache-promotion boundary.
Backend/public branch routing, current observations, cleanup and ordinary SDK/
platform qualification remain pending. These changes grant no public native branch
admission, historical package qualification, Rustler/Kubernetes implementation or
live crash/persistence-interruption qualification.


### Fenced completed-child absence

`Engine::qualify_branch_child_absence` requires `BranchChildAbsenceRequest` with
an exact retained `BranchCompletion`, expected current child receipt, distinct
operation ID, request hash and explicit quiescence. A valid serialized proof or
SDK row cannot manufacture the original completed registry context. The registry
requires the exact completed result and no active original borrower. Both source
and child observation gates exclude retained mutations, including during work
quarantine. The original opaque boot enrollment must match the current domain
and actor epoch; ordinary collection proves that exact child is gone and that no
current boot/transfer for its namespace remains. Both runtime caches must report
no child handle. Bounded read-only SDK row and creation-reservation absence plus
unredirected directory absence are rechecked with the same caller deadline before
and after proof construction. No SDK shutdown/delete, cache retirement or backing
release is dispatched. A foreign row, partial directory, symlink, active worker,
changed epoch or missing original result remains uncertain.

`BranchChildAbsence` is historical request-correlated positive namespace absence,
not an assertion that the caller's expected material head previously existed.
The future guarded store consumer must bind it to its own saved head and frozen
branch authority. Issuance repeats the current checks even for an identical
request; it never acknowledges an old absence against recreated material. This
boundary deliberately remains separate from original held-delete resolution and
backing-removal confirmation.

Protocol two routes `qualify_branch_child_absence` through exact immutable branch
approval and the reserved observation/control lane with a thirty-second ceiling.
Its required nonnullable `branch_child_absent` proof and request each have a
68-KiB limit. All branch proof terminals use the finite branch output path, now
72 KiB per frame including envelope, with the same 65-control-frame ceiling,
unchanged event allowance and room for both ordinary observers. Generic small
control output cannot carry branch proof. Domain, package platform, original
completion and exact request correlation precede success; no streams are accepted.
Public branch feature admission remains disabled. Synthetic wire/file/process-
record models establish no live VM, deletion, isolation or platform qualification.


### Guarded dependency retirement and v32

The Elixir backend now routes an approved deleted native child's saved authority
through the fenced qualifier. `NativeResolution` marks only its captured reference
quiesced after successful bridge quiescence and worker claim. The same reference
and absolute finite budget reach proof collection; no SDK row or plain absence
can substitute for the typed response. Production feature/assignment policy remains
closed while native branch admission is disabled. Semantic transport tests exercise
the same post-policy sequence without approving a future descriptor.

The exact retirement request is derived from the saved original completion,
expected child head, fingerprint and observed child version. Memory and encrypted
PostgreSQL reject a stale child proof even when the source guard is fresh. One
paired transaction retains immutable proof/original version, marks only that
source dependency retired and preserves original creation, source/child material,
other dependencies and all extra backing charges. Public explicit retirement keeps
the native authority fence through the final guarded store commit. This establishes
neither deletion nor backing removal. Backing-release integration stays pending.

Selective v32 carries retirement proof; v30/v31 retain exact earlier bytes and
strictly reject a new field in an older envelope. Fresh BEAM reading needs no
native tools. Historical experimental retired/closed states without this proof
remain readable and do not become new evidence; ratification of an earlier retired
state needs fresh fenced proof and retains its original retirement timestamp.
Current stores still do not advertise the complete native branch capability.

## Original backing accounting acknowledgement and public routing

`Engine.release_branch_backing_checked` binds the full original completion,
expected source/child tombstone heads, explicit quiescence and host backing-removal
confirmation to a canonical request. Exact original completed context and no
active original borrower are checked before admission and again in the accounting
worker. Existing ordered gates, original collection and bounded namespace absence
precede the protected acknowledgement ledger. Exact ledger retry releases no
second charge and does not touch recreated material. No SDK deletion or filesystem
cleanup is dispatched. The DTO is shared-engine authority suitable for a future
Rustler bridge; the Port wire representation cannot manufacture enrollment.

Protocol two/Elixir use the native-only `release_branch_backing/4` backend entry.
The public API holds native helper/controller fencing through durable request
acceptance, captured owner/epoch dispatch and final paired guarded store closure.
Accepted source/child heads and independent source approval must match. One
absolute finite budget limits this sequence; a missing, late or mismatched reply
leaves the exact accepted request and all public backing charged. An explicit
retry uses that same request. Selective v33 retains immutable request and optional
typed acknowledgement, preserving all previous envelope bytes. Completed saved
acknowledgements return idempotently without a replacement helper or another
namespace observation. HTTP retains its existing absence path and rejects this
native-only backend operation before transport dispatch.

Deterministic file/row/protocol/public-store models establish this foundation;
they grant no live SDK or rebuilt-package qualification. Public native branch
admission and every full-parity acceptance row remain pending. Partial/absent
resolution, prepared-retirement histories, normal replacement and ordinary
platform/source/consumer acceptance remain required. Crash validation is deferred.

## Checked original held-child deletion absence resolution

`Engine.resolve_held_branch_deletion_checked` validates full original held
completion, its exact root receipt, a distinct operation/canonical request digest
and explicit caller fencing. It matches the retained completed context and checks
active borrower exclusion before reading or changing deletion history. Existing
original returned-worker, opaque collection, namespace absence and protected
resolution/cache retirement checks remain authoritative. No SDK shutdown/delete,
filesystem cleanup, dependency retirement or backing release is dispatched.

Protocol two/Port/Elixir correlate the required nonnullable proof with the exact
request, original branch approval, domain and package platform. The request caps
at 68 KiB, proof at four KiB, and budget at 30 seconds. This control entry stays
available during ordinary admission quarantine; the existing finite branch
terminal buffer preserves both observers. Legacy protected resolution records
retain their schema and serialized fields. Only the checked boundary accepts the
new canonical request; raw receipt-only control cannot replace it on the wire.

Shared synthetic macOS/Linux fixtures and private deletion/protocol models
establish no SDK/platform qualification. Managed request/version retention,
codec/store proof consumption, public absence resolution and explicit
continuation/residual cleanup routing remain required before native activation.
The shared Rust DTO and engine retain the future Rustler boundary; no bridge
reimplements SDK lifecycle logic. Crash validation remains deferred.

## Durable original held-delete request and public absence resolution

The host now freezes the claimed management version, original delete version and
full completion/root-bound helper request before resolution IO. Claims and
explicit retries cannot replace it. Selective codec v34 retains pending intent
and typed absence acknowledgement; earlier v30/v31/v32/v33 bytes and strict
reader upgrades remain unchanged. An uncertain original held-child delete cannot
be marked deleted through generic absence or a generic record write.

Public Machines.resolve with deleted disposition retains the native original
helper/controller fence through user-version claim, accepted request, scoped
resolve_branch_deletion backend dispatch and final guarded proof commit. One
finite deadline covers this sequence. Normal IO renewal changes no request.
Only the child's ordinary reservation is released; source dependency, extra
backing, creation/material and command history remain for their separate
transactions. Memory/PostgreSQL retain proof and resource changes atomically.
HTTP keeps the existing observation route and rejects the native-only entry.

Synthetic store/backend/public peers establish the transaction/correlation
boundary without SDK/VM dispatch. Explicit continuation/residual cleanup,
partial/absent creation/release resolution, prepared-retirement history, normal
replacement and ordinary platform/source/consumer qualification remain required.
No complete native branch store marker or public capability is enabled by v34.
Crash validation remains deferred and distribution approval separate.


## Original entered-job resolution borrowing

`PreparedBranchWorker::retain_creation` now freezes the complete bounded
`BranchCreateRequest` before SDK entry, including an initial activation choice.
The automatic `Engine::create_branch` path uses it. The existing `retain` API
keeps its unbound behavior; a later resolution cannot adopt that legacy entry by
matching names, copied labels or partial native intent.

`Engine::retain_branch_resolution` uses a finite control allowance and explicit
quiescence to select only that exact original entered entry. It checks original
registry/domain/runtime identity, pinned source root/marker/database and live
helper epoch. A synchronized exclusive borrower rejects an active creation
borrower or worker. Prepared-only and completed work use separate APIs. No SDK
inventory query, manager reconstruction, journal mutation or replay occurs.

The opaque `RetainedBranchResolution` exposes only in-memory phase, under its
captured deadline/cancellation and bounded control admission. It is neither
liveness nor child readiness/absence/disposal evidence. Dropping it releases only
the borrow; every original gate, spool, runtime/manager and backing allowance
remains retained. Future entered disposal must use that context and independent
durable proof before host/store reservations can change. No Port message,
public backend operation, codec envelope or capability marker is added here.
Six new inert metadata/PID/spool models cover exact identity, original ownership,
exclusive borrowing, active workers, request/initial-activation substitution,
foreign owner, changed root, missing registry, finite cancellation/deadline and
phase-only semantics. They create no VMM or live owner-loss campaign.


## Original disposed child fresh absence

UnbootedBranchChildAbsence is distinct from BranchChildAbsence, which requires
real boot/guest completion. Its complete original disposal is correlation only:
Engine.qualify_unbooted_branch_child_absence requires the exact retained disposed
archive, same runtime/domain and protected synchronized ledger. Original child
epoch quiescence plus current SDK row/reservation and original-directory absence
are checked before and after issuance under source/child gates and a reserved
material-control allowance. The source may remain running; no source process
collection, manager/boot enrollment, SDK mutation, filesystem cleanup, dependency
retirement or native capacity release occurs. Every subsequent qualification
rechecks current absence and preserves recreated material. Finite cancellation/
deadline and protected context checks surround the observation.

Bounded protocol-two requests/results and Elixir readers bind full disposal,
provenance, immutable creation, distinct canonical request, exact approval/domain,
original epoch/platform and zero output. Seven native private projection models,
three wire contracts, one helper catalog/control model and shared synthetic Elixir
readers establish these boundaries without SDK/VMM qualification or a live crash
campaign. Public/store retirement now consumes this proof under one helper/
controller fence, with source/child graph and child-version correlation. Selective
v38 preserves immutable disposal plus retirement and retires only the dependency
flag; all backing stays charged. Memory/PostgreSQL share paired commit/rollback
and fresh-reader contracts. Host backing closure and remaining ordinary source/
platform acceptance stay required. No public branch
admission or store marker is enabled; upstream SDK/research sources stay untouched.


## Original released-child deletion absence resolution

`Engine::resolve_released_branch_deletion_checked` consumes a distinct request
with the exact original completion, completed initial/explicit release, current
release receipt, new operation identity, canonical digest and caller quiescence.
It matches the retained completed context and original deletion intent; SDK rows
cannot reconstruct either. Active original borrowers/workers, changed boot or
identity, foreign epochs and an uncollected original manager reject.

The reserved material-control allowance performs bounded positive original
collection and SDK row/reservation/directory absence without SDK stop/delete or
filesystem removal. Unresolved deletion keeps its original gates and work. A
successfully deleted child whose ordinary transient leases already retired uses
fresh paired source/child gates. The protected domain journal records schema five
with a distinct released proof binding completion/release/deletion hashes and the
exact request. Earlier held schemas and released schema four retain their bytes
and bounds; schema five shares the existing 160-KiB released limit. The previously
reserved second result-metadata lease remains retained.

Exact recorded lookup is historical evidence for only its saved request; a new
request cannot rewrite it. File and directory sync are repeated before returning
a recorded proof, so a prior uncertain sync does not become an acknowledgement. Returned resolution retires transient deletion leases
only after original handle retirement. Source/snapshot dependency and persistent
backing charges require their existing separate retirement/closure workflows.
The distinct protocol-two entry is bounded to 132-KiB requests, four-KiB proofs,
30 seconds and zero output, with exact approval/domain/platform correlation and
reserved control/terminal capacity while ordinary admission is unavailable.

Public/store consumption now persists a distinct released intent before IO and
consumes its exact proof under the original helper/controller fence and deadline.
Selective v40 freezes claimed management/delete versions, completion, release and
current head; older envelopes reject this variant. Only the ordinary child slot
retires, with source dependency and backing requiring their separate proofs.
Released continuation/residual cleanup and ordinary SDK/platform qualification
remain required. This path neither enables public
native branch admission nor performs deferred crash validation. Deterministic
file/row/callback models and synthetic cross-reader fixtures establish only their
stated boundaries; upstream SDK and research source remain unmodified.


## Original released-child final deletion continuation

`Engine::continue_released_branch_deletion_checked` is separate from observational
resolution and held-only action grants. Its exact completion/release/current head,
new canonical operation/request and quiescence bind the original retained context.
The shared collector requires returned owner work, original positive collection,
matching original manager, protected stopped material and bounded leaf inventory.
Schema six freezes Finishing before normalization and one final SDK deletion.
Only the same unentered grant may continue; entered Deleting never replays.
Positive absence may also preserve an original in-memory frozen grant before its
Finishing publication. Another grant or entered final step cannot be adopted.

SDK success requires the protected Deleted phase, returned original worker and
exact saved continuation before a distinct bounded acknowledgement is issued.
Recorded completion is synchronized again before acknowledgement. Unknown final
results retain the original gates/work and can resolve only by positive bounded
namespace absence, preserving the continuation and its original intent digest.
That historical absence proof cannot substitute for SDK success. Earlier record
schemas and proof shapes remain exact; the existing 160-KiB released journal bound
and retained metadata allowance fund the extension. Source dependencies and full
snapshot/backing charges retain their independent retirement/closure workflows.

Protocol two/Port use the original approval catalog, Delete capability, zero
output, 30-second reserved control admission, 132-KiB request and four-KiB proof
limits, exact receipt/domain/platform correlation and finite terminal capacity.
Public/store continuation consumption now persists a distinct released grant
before IO and consumes its exact SDK-success proof under the same captured
helper/controller fence and absolute deadline. Selective v41 freezes claimed
management/delete versions, original completion, release and current head. Earlier
envelopes reject the new variant and earlier bytes stay exact. Independent pending
observational/continuation histories survive completion through the other route;
positive absence cannot become SDK success. Only the ordinary child reservation
retires. Released filesystem residual cleanup and ordinary SDK/platform
qualification remain pending. No public admission or package
approval is enabled and crash validation stays deferred.


## Original released-child residual cleanup

`Engine::cleanup_released_branch_deletion_checked` consumes a distinct cleanup
request bound to the full retained completion, exact initial/explicit release,
current head, new operation/canonical digest and caller quiescence. The shared
held/released removal worker requires original returned deletion context, positive
original collection, SDK row/reservation absence and the exact pinned original
directory identity. Missing/replaced roots cannot create cleanup authority.
Descriptor-relative bounded removal preserves source/sibling link targets and
never invokes SDK stop/delete, guest work, volume detach or backing retirement.

A separate protected released cleanup ledger uses schema two and a 160-KiB cap;
held schema one preserves its bytes and 80-KiB bound. The main released proof
keeps its existing schema/shape. Frozen continuation history, including a retained
unpublished grant, remains part of the original deletion digest. Cleaning precedes
unlink; only the same recorded request may resume partial removal or acknowledge
an already removed path. Matching primary completion may finish only its cleanup
audit without traversing recreated material. Different observations cannot replace
an entered cleanup grant. Both ledgers are synchronized before returning a
recorded released acknowledgement.

Released deletion reserves a third retained 128-KiB metadata allowance before any
uncertain SDK work, funding the independent cleanup ledger without ordinary
metadata admission during quarantine. It remains charged alongside release/result
metadata and persistent backing after transient cleanup work retires. Control
admission, original descriptor/work leases and one ordinary observer stay bounded.

Protocol two/Port/Elixir carry the distinct cleanup request and required existing
positive-absence proof under exact approval/domain/platform correlation, Delete
capability, zero output, 30-second reserved control admission, 132-KiB requests and
four-KiB proofs. Durable/public cleanup acceptance and ordinary SDK/platform
qualification remain pending. No capability admission or package approval is
enabled, and crash validation stays deferred.
