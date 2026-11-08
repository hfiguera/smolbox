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
