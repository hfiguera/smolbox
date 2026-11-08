# Embedded Port HTTP parity completion audit

Status: **incomplete**, October 15, 2026. The full P0–P9 objective remains active.
This audit follows each numbered requirement in the
[implementation plan](embedded-port-http-parity-implementation-plan.md).
The [coverage manifest](embedded-port-http-parity-coverage.json) remains the
operation/arity/specification acceptance inventory: all full-parity acceptance
rows are pending. No required feature is removed from scope.

`Implemented foundation` below means inspected source and deterministic contracts
exist; it does not establish the phase exit gate or native platform qualification.
The exact engine 0.1.0 offline evidence remains historical. Changed engine 0.2.0,
manifest 3, protocol 2.0 packages need their own ordinary platform/consumer evidence.
Crash qualification and distribution approval remain false and separate.

Ordinary regression at worker-stage commit `8314577`: the full Elixir suite passes
1,051 cases (4 doctests, 6 properties, 1,041 tests), with 42 runtime/deferred-crash
cases excluded. Rust passes 675 ordinary units and 56 protocol contracts; the
exact non-VM branch rejection worker passes separately. These are regression and
contract checks, not native branch, changed-package/platform or PostgreSQL-server
qualification. A passing HTTP terminal-peer case logs a Bandit close-frame
exception; that diagnostic remains unresolved.

Held-child first-boot foundation: the native retained coordinator now explicitly
selects its original snapshot and source UID-share directory through public SDK
AgentManager APIs. It opens existing disks without formatting and avoids the
SDK convenience fork's retry, cleanup and automatic release behavior. A protected
first-boot journal binds the publication, pinned directory identities and original
epoch before dispatch, then records SDK return and opaque boot enrollment.
Original manager/runtime/gates/backing remain retained on cancellation or unknown
outcomes. Bare-pack inputs are fully rehashed and pinned from creation caches;
legitimate later disk growth does not change their original manifest geometry.
The whole branch allowance now reserves 24 work descriptors and two child slots,
leaving the existing eight control descriptors and two observers available.
Seven new non-VM models cover explicit configuration, replacement rejection,
epoch binding, no replay, unresolved returns and journal/input protections.
These models establish no actual SDK boot or guest initialization qualification.
A native-only initialization step now uses a fixed bare-guest program through
public SDK AgentClient APIs and a header-first bounded relay. Protected entry
binds original opaque boot enrollment, child, program digest and fresh challenge.
A deadline/cancellation guard closes only that observation socket; unknown entry
never retries or releases capacity. Exact successful confirmation records a
separate IdentityReady phase, retaining the original manager/gates/backing.
Seven more non-VM models cover program/child binding, confirmation, bounded SDK
exchange, oversized headers, deadline/cancel, unchanged original source/child rows
and protected no-replay transitions.
These are protocol/file models; no guest program ran or guest initialization was
qualified. Actual boot/initialization qualification, explicit held release, final
initialized publication, manager handoff, public proof/store integration and
ordinary platform acceptance remain pending. Public branch admission is disabled;
crash validation is deferred.


Original-job release foundation: the retained coordinator now distinguishes
initial helper acknowledgement from explicit held activation through public SDK
agent requests. Capability negotiation and exact bounded responses precede proof;
missing/duplicate/malformed acknowledgements never become success. Protected
first-boot/material entry records bind the independent child, original opaque
boot enrollment, initialization digest, caller operation/request and release mode.
Only the exact agent outcome permits the full-row CAS changing the held flag.
A distinct release material proof preserves immutable creation identity and links
both synchronized journal completions before cold restart becomes eligible.
The earlier reserved Initialized shape remains readable but grants no restart
without actual release material. Exact completed lookup recovers acknowledgement
without replay or journal mutation. Seven private non-VM models cover these
boundaries and both SDK request paths; no guest/VMM is qualified. The native
coordinator still retains its original manager/runtime/gates/backing and creation
budget. Public delayed held release needs fresh store/version admission after
manager handoff. Public held-creation finalization, ordinary lifecycle qualification, entered
resolution, public codecs/store histories/dual reservation and ordinary platform
acceptance remain pending. Public native branches stay disabled.


Original manager handoff foundation: finish_child now verifies original live
source/child boot authority, completed IPC, unique retained ownership and exact
synchronized completion before installing the same manager into the common
direct-manager cache. Original opaque enrollment, source SDK runtime and domain
remain attached. HeldReady grants observation only; held commands and ordinary
start/stop reject. Released children retain their authorized material proof.
Temporary roots/gates/work/parser/FD/launch allowances retire after transfer;
backing remains charged. Completed bookkeeping uses 128 KiB per child under a
separate 128-MiB limit, preserving the executing SDK-parser pool and both control
observers. Unresolved backing/context survive registry teardown. This does not
implement public backing retirement or replacement enrollment. Continuing-source
observation requires protected current child heads plus original live-source
witnesses; inventory alone cannot override dependency state. Ordinary direct-
manager commands use the owned worker path, avoiding SDK-manager reconstruction.
Seven additional non-VM models cover accounting, held restrictions, original-token
rejection and metadata candidacy. The ordinary Rust sweep passes 714 units and
56 contracts. The full ordinary Elixir suite passes 1,051 cases with 42 runtime/
deferred cases excluded; the earlier terminal close-frame diagnostic does not
reproduce in this run, with no fix claimed. They establish no actual SDK manager handoff,
source command, stop/restart or platform qualification. Public/store/codec routing,
fresh-budget held release/deletion, multiple-child sources, backing retirement/
replacement and ordinary acceptance remain pending. Public branches stay disabled;
new persistent limits need negotiation before activation.

Fresh-budget held-release foundation: release_held_branch uses the completed
original context, manager and opaque enrollment with a new absolute budget.
Current protected source/dependency authority and ordered gates precede one-shot
SDK activation. A separate 128-KiB result lease is funded before dispatch without
duplicating retained disk charges. Both journal completions and exact tracked
receipt promotion precede temporary lease retirement. Unknown entry retains its
leases; historical results never reconstruct a manager or re-enroll a missing
handle. Seven additional private non-VM models cover result recovery, no replay,
gates, fresh admission and persistent accounting. The Rust sweep passes 721 units
and 56 contracts; five targeted Elixir admission/coverage cases pass. These are
regression/model evidence only. Public release/version/store routing, deletion,
dependency/backing retirement, multiple-child sources and actual platform
qualification remain pending. Public branch admission stays disabled.

Existing-child source foundation: native branch_preflight now uses bounded
dependency reads and the original live source witness independently of capture
preflight. Every earlier leaf requires its published origin and protected current
material. Only the exact entered preparation can exempt its new unpublished
child. The checks follow worker preflight/collection, publication, boot,
initialization, release and handoff; prepared-only retirement preserves siblings.
Four additional private models cover successive source heads, unchanged earlier
child, pending/exempt boundaries, unknown siblings and missing original owner.
The Rust sweep passes 725 units and 56 contracts; 67 branch-focused cases pass.
Strict Clippy/API docs, five targeted Elixir cases and the exact rebuilt-debug-
helper ordinary namespace-rejection/normal-collection fixture pass.
They run no SDK branch and do not qualify real child isolation, live multiple-child
sources or package/platform behavior. Public branch routing, durable dual
reservation, deletion/retirement/replacement and ordinary acceptance remain
required. Capture and ordinary source lifecycle dependency exclusion are unchanged.
Public branch admission stays disabled; crash validation stays deferred.

Original held-child deletion foundation: native explicit deletion routes completed
held children through original manager/opaque epoch collection, preserving ordinary
held stop/start rejection. A protected domain record survives SDK child-directory
deletion and distinguishes Collecting, Collected, Deleting and Deleted. Exact
collection precedes stopped-row CAS and one SDK deletion; bounded row/reservation/
directory absence precedes completion. Unknown attempts retain gates/work/SDK lease
as applicable and never replay. Only exact original cache entries can retire after
completion; persistent bookkeeping and source backing remain charged. Five private
non-VM models cover ordering, absence, uncertainty/accounting and protected records.
The Rust sweep passes 730 units and 56 contracts. Strict Clippy/API docs, five
targeted Elixir cases, 13 ordinary/deferred-selection Python guards and the exact
rebuilt-debug-helper ordinary rejection/collection fixture pass.
They do not qualify actual guest shutdown or SDK deletion. Public branch routing/
store histories, pre-handoff child disposal, explicit unknown deletion resolution,
dependency/backing retirement, replacement and ordinary platform acceptance remain
pending. Public branch admission remains disabled and crash validation is deferred.

Unknown held-delete resolution foundation: explicit native resolution requires
caller quiescence, original returned worker/gates, opaque epoch collection and
complete row/reservation/directory absence. It never calls SDK shutdown/deletion.
A distinct operation/request-bound ResolvedAbsent proof can resolve disappearance
during any entered deletion phase without asserting SDK success. Exact recorded
lookup rejects a different request and performs no SDK work or journal rewrite.
Legacy schema one retains its 64-KiB limit and omitted-field bytes; resolved schema
two has an 80-KiB bound. Reserved material-control admission works during quarantine
alongside one ordinary observer. Cache retirement precedes temporary lease release;
source backing, persistent bookkeeping and wider quarantine remain. Five additional
private models pass these boundaries, including history, version and proof checks.
An additional read-only SQLite model verifies that the absence query uses the
caller's original cancellation/deadline rather than a fresh observation budget.
The Rust sweep passes 736 units and 56 contracts; all 10 deletion-focused cases
pass. Strict Clippy/API docs, targeted Elixir and ordinary/deferred guards pass.
The final rebuilt debug helper's exact ordinary rejection/collection fixture passes.
They do not qualify actual SDK deletion, absence resolution or platform behavior.
Public store/protocol/version routing, private schema/limit negotiation, collected
residual-child cleanup, pre-handoff disposal, dependency/backing retirement/
replacement and ordinary qualification stay
pending. Public branches remain disabled; crash validation remains deferred.

Collected held-child continuation foundation: an explicit fenced request can now
finish deletion after original collection when exact held material remains. The
original leases and epoch proof precede a frozen schema-three Finishing grant and
stopped-row CAS. Only the same as-yet-unentered step can continue with a fresh
budget; entered Deleting cannot replay. Shared final deletion checks preserve
ordinary deletion behavior, exact SDK lock closure and positive absence before
completion. Resolution retains and hashes the continuation binding separately
from SDK success. The old work/parser/gates and one reserved control allowance
follow actual host-worker return; backing/bookkeeping and wider quarantine remain.
Eight private models cover these gates, one-shot callbacks, histories, compatibility
and accounting without SDK deletion or a VMM. They include bounded dependency
inventory and pinned cache-shape checks before entry, preserving source links and
excluding private volume-detach utilities. The Rust sweep passes 744 units and
56 contracts, including all 18 deletion cases. Public continuation/version/store/
protocol routing, private schema negotiation, pre-handoff disposal, unproved or
partial residual cleanup, backing retirement/replacement and ordinary platform
qualification remain pending. Public branches remain disabled; crash validation
stays deferred.

Collected held-child residual-cleanup foundation: explicit caller-fenced cleanup
now handles partial original directories after original epoch collection and SDK
row/reservation absence. The directory descriptor remains pinned across SDK
entry, preventing inode reuse before acknowledgement. A separate protected
Cleaning/Cleaned record binds the frozen request, original intent/continuation and
parent identity without changing primary record schemas. Bounded descriptor-
relative removal preserves source/sibling link targets; no SDK deletion repeats.
Recorded partial or removed-root cleanup can finish forward with a fresh budget;
unrecorded absence cannot create a cleanup grant. Matching acknowledged primary
absence proof can finish only the residual audit without touching new material.
Exact primary resolved proof precedes cache/transient retirement. Original
work/gates/parser reservation and one four-descriptor/32-MiB material-control
allowance keep an observer available under quarantine; backing/history and wider
quarantine remain. Eight private non-VM models cover these boundaries. The Rust
sweep passes 752 units and 56 contracts, including all 26 deletion cases; targeted
Elixir/selection checks and the rebuilt ordinary worker fixture pass. This is not
live SDK or platform acceptance. Public cleanup/version/store routing, released/restarted children, pre-handoff disposal,
unproved residual cleanup, backing retirement/replacement and ordinary platform
qualification remain pending. Public branches remain disabled; crash validation
stays deferred.

Native branch backing-release foundation: explicit release now requires caller
quiescence, host backing-removal confirmation, original completed registry context
and ordered source/child gates. Original source process/epoch quiescence and
opaque child collection, empty runtime PID caches and absent source/child SDK
rows, creation reservations and directories precede a fresh protected receipt.
The synchronized request/publication/context-bound proof releases only the exact
native material charge. Exact acknowledgement can finish a recorded result
without requalifying or touching new material. Persistent history, sibling
charges and wider quarantine remain; only already released completed entries can
drop normally at registry shutdown. Seven private non-VM models cover these
boundaries. The Rust sweep passes 759 units and 56 contracts; targeted Elixir/
selection checks and the rebuilt ordinary worker fixture pass. The host assertion
covers moved/out-of-namespace material;
this is not native forensic proof of all file removal. Public retirement/storage-release
routing, durable dual reservations, replacement and ordinary SDK/platform
qualification remain required. Public branch admission stays disabled; crash
validation remains deferred.

Scoped public branch coordination: source/child backend calls now carry their
own saved record authority across preflight/create/completion/release. Explicit
resolve/retire/storage-release pin one native owner/epoch, require helper quiescence
and worker claim under the shared authority fence, and retain that fence through
the guarded final store transaction. Paired observations never retarget a stale
or unavailable pin. HTTP client/result/store behavior stays unchanged. Seven
semantic transport models and four public/store coordination models cover scope,
replacement lookup, busy/stale/competing authority and retained public accounting.
The final ordinary Elixir suite passes 1,062 cases at eight-way concurrency with
the same 42 runtime/deferred exclusions; no added Credo findings are reported,
while 52 existing repository findings remain a P9 gate. These models use validated
public branch records; they do not qualify native assignment enrollment, branch/material proof histories or SDK behavior. Native
Port routing, durable branch authority/codec integration, engine backing-release
acknowledgement and ordinary qualification remain pending. Public native branch
admission stays disabled; crash validation remains deferred.

Port branch source preflight: a typed major-two branch_preflight request now
reaches the existing shared-engine original-owner source probe. Material receipt,
matching domain, branches feature version and a maximum 30-second budget precede
entry. Only a zero-output running source observation with PID/resources and
explicit offline/unmapped/unmounted configuration can complete it. The probe
consumes work admission and grants no fork, creation or guest-idleness authority.
Scoped branch_source construction/decoding checks saved source identity/resources;
current packages remain gated before dispatch. Three Rust protocol contracts,
one semantic helper peer and four Elixir contracts cover the shared synthetic
fixture and disabled-package behavior. The Rust sweep passes 763 units and 56
contracts; the ordinary Elixir suite passes 1,066 cases at eight-way concurrency
with the same 42 runtime/deferred exclusions. These are not live source/SDK/
platform qualification. Remaining branch operations, durable authority/codec integration,
package activation and full ordinary qualification remain pending. Public native
branch admission stays disabled; crash validation remains deferred.

Shared-engine branch creation workflow: create_branch now composes original
protected preparation, material publication/first boot/initialization, optional
initial activation and manager handoff under one absolute budget. Typed input
freezes source, child and operator approval; held versus non-held mode requires
exact absence/presence of a distinct initial activation request before admission.
Post-intent failures remain uncertain, with original pending state/gates/work/
backing retained. Read-only completed lookup checks the exact request against
original registry results before new admission, without SDK inventory or owner
reconstruction. Conflicts, duplicates, corrupt results and changed activation
reject. None proves no absence or retry permission. Bounded material control
supports lookup during quarantine without releasing reservations. Six private
non-VM request/result/accounting models cover these boundaries. The Rust sweep
passes 769 units and 56 contracts; targeted Elixir/selection checks pass. They do
not qualify a successful SDK fork or the full live workflow. Port/durable integration,
replacement and ordinary platform qualification remain required. Public native
branch admission stays disabled; crash validation remains deferred.

Branch creation Port contracts: protocol two now routes typed creation and exact
historical completed lookup through the shared engine. Feature negotiation and
full immutable operator approval equality gate both requests. Creation uses work;
lookup uses observation admission. Typed publication/child-origin/initial-release
proofs preserve engine serialization and hashes, enforce source/child/activation
correlation and reject crossed platforms, legacy protocol and streamed output.
The helper catalog is optional for legacy configurations; present catalogs are
major-two-only, finite and unique. Each branch completion is at most 64 KiB.
Branch terminal frames have a distinct 68-KiB control allowance; ordinary frames
keep 4 KiB and event storage is unchanged. The combined finite queue preserves
space for control replies during stalled event output. Synthetic held/released
fixtures, helper/catalog/session contracts and stalled-output tests pass. The Rust
sweep passes 776 units and 56 contracts; five targeted Elixir cases, 13 selection
guards, strict Clippy/API docs, formatting and clean source verification pass.
These checks do not qualify a successful SDK fork or public branch lifecycle.
Elixir now reads the same canonical intent/publication/release hashes and validates
exact request/domain/platform, operation kind and zero output. Operator catalogs
forward only under the branch feature and bind approved profile host overheads,
preserving profile-based public child accounting. At most 32 policy IDs by 32
distinct profile overheads are allowed; one ID cannot change backing resources
and duplicate variants reject. Current packages reject both operations before
native dispatch even with an exact catalog. Full catalogs fit a bounded 512-KiB
helper config; configurations without branch catalogs retain their 64-KiB limit.
Durable authority/history/codec/dual
reservation integration, public backend routing and ordinary platform
qualification remain pending.
Public branch admission stays disabled; crash validation stays deferred.

Branch material-history reader foundation: typed source-publication and child
release links now compose with growth/capture/resolution evidence. Exact prior
receipts and global operation IDs fence ordering; known growth/capture hashes,
checkpoint head, platform/lineage and backing disk totals must agree. Source
publication can advance a material revision without changing record bytes.
Child release is a distinct sealed root link, not a source mutation or permission
to extend that child's journal. Native identities carrying these links require
the complete chain. Branch histories have a 1,024-link ceiling; existing
branchless histories retain 288. Two entirely synthetic platform fixtures pass
every prefix through the actual Rust journal validator and Elixir reader. Typed
links in modeled attached-command evidence select v29 and reject older,
compressed or trailing envelopes. Existing branchless encodings are unchanged.
Five new Elixir models, 70 codec/history cases, the 1,077-case ordinary Elixir
suite, 778 Rust units and 56 contracts pass. These checks are not source/child
store transactions, normal durable replacement or live SDK qualification.
Native branch authority, prepared-retirement history, guarded source/child
projection/dual reservations, public lifecycle routing and ordinary platform
acceptance remain pending. No branch-store capability or public native admission
is advertised; crash validation remains deferred.

Ordinary Linux package qualification: the [scoped package evidence](../evidence/embedded-port-http-parity-linux-package.json)
records engine 0.2.0/manifest 3 public offline lifecycle consumers on current
Elixir 1.20.4/OTP 29 and minimum Elixir 1.18.4/OTP 27, with Rust absent. Both
consume the same saved archive and exact rebuilt package; HTTP-only lanes also
pass with native assets absent. A separate current-toolchain public PTY run
passes binary input/output, resize, duplicate-open identity, observed exit, codec
17 and slot release. All public runs delete owned machines, leave empty SDK
inventories and zero reserved slots, and exercise ordinary draining and Runtime
replacement. Package modes now exclude group/other writes independently of cache
or umask. The lab powered off normally with no helper, VM or BEAM remaining;
systemd reports success before the runtime limit. This qualifies the recorded
Memory-store offline/PTY scope only: feature-specific native acceptance, full
P0–P9 completion, macOS changed-package qualification and distribution approval
remain pending. Historical evidence is unchanged; crash validation stays deferred.

Ordinary SDK export qualification: a freshly built macOS development package
successfully created/started/stopped a real approved imported source through the
normal Port path. The opt-in shared-engine fixture consumed its original receipt
in the actual enrolled SDK namespace; initial storage/COW initialization and
unstarted-manager construction/cleanup passed. Subsequent helper startup failed
because SDK template copying inherited read-only mode before growing a larger
disk. Its original child was collected, but cleanup rejected SDK format/readiness
files absent from the model. The qualifier retained its owner and ledger rather
than forcing loss or reconstructing a manager. Code now formats at the approved
baseline, makes owned copies writable, grows via public SDK APIs, requires exact
format markers for launch and captures bounded SDK runtime files. Post-collection
shorter files grant cleanup custody only. These changes still need ordinary
requalification; neither helper launch nor export/import acceptance is complete.
Public exports remain disabled, and no crash campaign was performed.

Fresh source disk sizing: OCI and imported/prepared container creation now format
at the one-GiB baseline and grow only owned writable copies through public SDK
APIs before minting the receipt. Exact requested sizes are checked; VM-pack
seeding and existing-machine material transitions retain their separate paths.
Inert byte/marker-preservation and no-shrink models cover growth. The opt-in disk
API witness uses approved templates and disposable explicit paths without a
manager, domain owner or VM. The actual macOS disk witness passed three-GiB storage
and two-GiB overlay growth, full original-prefix hashes, immutable template
identity/content and explicit temporary-file cleanup. It cannot establish guest
startup or export success. Its [scoped evidence](../evidence/embedded-port-http-parity-template-growth-macos.json)
also records passing current/minimum HTTP-only consumers against one saved archive
with Rust and native assets absent; no native public consumer is qualified.

Staged artifact credit: a new private non-VM witness packs more than 16 MiB and
uses the production uploader/client/deadline control to pause an incomplete
registry acknowledgement. Only one MiB is read in bounded 256-KiB calls until the
complete body returns credit. Resume verifies all ranges/blob bytes; API cancellation
and deadline expiry keep source/staging authority and send no next chunk or commit.
Both reserved observers and health remain usable under full work metadata.
Single blob completion is explicitly insufficient publication proof. Native
registry clients now disable automatic library retries. This is staged-file
credit/retirement evidence, not guest/worker, OS peak, full public publication or
whole-pipeline acceptance; those gates remain pending.

Imported-container source qualification foundation: a shared-engine opaque handle
now retains the stopped source's original gate/job/domain and its receipt-bound
sidecar under the local-artifact or prepared-registry creation cache. It rechecks
the exact directory/inode/version, owner, immutable mode, single-link identity and
original domain binding/lock. Budgeted reads verify the full content digest, SDK
footer checksum, bounded manifest and complete nested asset inventory. Every
layer's tar digest is checked independently, with manifest ordering preserved regardless of archive order.
Logical expansion (including sparse holes) and entry counts are recorded under
existing decompression/metadata limits. Decoded and synthesized sparse reads both
check the original budget. No mutable SDK layer-cache pointer/order,
cache repair, arbitrary caller path, host extraction or SDK lifecycle is used.
The coordinator now retains those inputs in the owned conversion path. Frozen
worker metadata binds original cache/inode/version and ordered layers. The worker
reopens and independently rehashes/inspects only that original input before guest
I/O; parent source/FD/job authority remains held through actual collection. A
second bounded sidecar pass streams tars directly into 64-KiB guest upload chunks.
Each guest file stays within the SDK's fixed four-GiB write ceiling; larger tars
use bounded sequential parts. Hash verification precedes fixed-path extraction,
with pipeline failure detection and explicit part removal before the next layer.
No cache query/rebase/pull, host tar copy or host layer mount is used for imports.
The exact imported flatten plan preserves manifest order and actual saved record
metadata without resurrecting baked environment/workload values.

An optional protected allowance marker funds all extracted logical content,
largest temporary tar, filesystem block/inode/xattr/metadata overhead and private
reserve before dispatch. Actual tar/artifact caps still share remaining staging.
Legacy budget/input/plan bytes omit new fields unchanged; strict older readers
reject imported markers. Non-VM source, snapshot, upload, plan, budget and scratch
models cover these boundaries. Ordinary SDK helper storage/mount/extraction/tar
semantics, local/registry export/import and exact-package qualification remain
pending. Whole-pipeline output-credit acceptance is also still pending.
Public native export admission and all full-parity acceptance remain disabled or
pending; this source foundation grants no helper or publication authority.

Pre-entry aborted-source transport foundation: protocol 2 carries the exact
quiesced `qualify_aborted_capture_source` control and distinct
`aborted_capture_source_qualified` outcome. Native adapter conversion and Rust/
Elixir validators bind the protected original intent, cleanup, unchanged material,
source state and canonical proof digest. Replies require exact receipt/operation/
request correlation and zero output; stage cleanup and material transitions cannot
substitute. Shared synthetic fixtures validate in the actual engine and both
wire implementations. A pure Port peer exercises reserved control capacity under
busy workers and modeled quarantine without restoring ordinary work. Public/store
consumption now persists distinct source qualification and the observation under
pinned/quiesced authority and current store guards. Memory/PostgreSQL retain source
material/history and unknown artifact accounting. Ordinary running/stopped
inventory cannot resolve an unknown native capture without the distinct proof.
Selective v27 and
`native_capture_abort_sources: 1` require reader/writer upgrades; tested HTTP and
v24–v26 envelopes remain compatible. Ordinary package/source/platform qualification
remains pending; checkpoint admission is still disabled.

Checkpoint catalog foundation: `CheckpointIdentity`, helper `CheckpointApproval`
and Elixir `CheckpointContract` bind immutable source identity, operator-only
path, native host/guest platform, current SDK and exact captured allocations.
Catalog validation caps 32 unique IDs and 64-GiB input without opening files.
Deterministic Rust/Elixir contracts reject crossed/oversized approvals and caller
paths; optional omission and feature-gated launch serialization preserve older
configuration. Native operation dispatch and Elixir wire contracts now cover
qualification, creation and absence with exact catalog/resource selection and
correlated receipt results. The ordinary non-VM installed-row fixture uses the
shared engine's approved-source creation entry point under one absolute budget.
Managed routing and selective v22 restore-source assignments now have a structural
reader/atomic reservation foundation with exact captured-profile approval.
Retained commands inherit the same assignment. Runtime requires the separate
native_checkpoint_sources reader before enrolling a future capable helper;
Memory and the PostgreSQL example implement it. Old native envelopes reject
restore-source assignments and HTTP bytes remain compatible. Capture/export/branch
histories, explicit resolution and ordinary restored-VM qualification remain
pending; this does not enable public admission.

Checkpointable startup foundation: fresh local/registry pack creation can bind
forkable into original material; start/preflight core and Port operations reject
untracked ordinary-record promotion. Non-VM contracts keep forkable and lineage
in the material hash, reject container/network/dependency profiles and require a
running preflight result. Source inspection additionally checks enrolled runtime
PID/birth and grants no idle assertion. Creation opt-in now has explicit true
wire/assignment routing, selective v23 persistence and a separate Runtime reader
gate. Ordinary/HTTP defaults remain omitted; capture's
separate material transition and ordinary running-source qualification are still
pending. No public checkpoint descriptor is added.

Capture material foundation: `capture_material.rs` and `MaterialJournal` define
distinct prepared/entered/completed capture evidence, request and original-source
binding, exact artifact/lineage and source-resume postconditions. Five non-VM
contracts exercise lost/unpersisted head, foreign PID/material/parent, growth
interleaving, duplicate/order/proof corruption, copied permits and in-place journal
changes. Capture pending state fences generic material verification. Old journals
omit capture fields. SDK dispatch and owned worker collection now connect to the
shared engine's capture coordinator. Distinct correlated proofs bind metadata,
artifact bytes, lineage and the same resumed source PID/birth. Parent checks
independently verify retained output before publishing a material transition.
One-time streaming retains staging/job allowances. Entered uncertainty preserves
staging and its allowance; only the enrolled exact source can stop normally
without resolving capture. Deterministic models cover these boundaries. Public
capture routing, saved store history and ordinary captured-source qualification
remain pending; this foundation does not admit public capture or claim guest
idleness.

Capture observation foundation: protocol-2 `inspect_capture`/`capture_presence`
look up only an exact journal-completed operation under an observation allowance,
machine gate, original creation marker and matching engine domain/database.
No recorded completion returns null, not absence/quiescence or replay permission.
Strict Rust/Elixir capture transition validators preserve the engine's canonical
capture proof domain, original receipt, request, source PID/birth and lineage.
Both channels require exact request correlation and zero streamed bytes. The
operation remains checkpoint-feature gated; no current public descriptor is
activated. Shared synthetic fixtures are verified by the actual engine, Rust wire
and Elixir validators. Durable saved histories and public backend publication
remain pending. Path-free protocol-2 capture now connects through the Port adapter
and a dedicated checkpoint stream to an incremental Elixir consumer. Exact
delivered size, digest and request correlation are required before transfer
success. Credits follow explicit consumer acceptance and artifacts are never
buffered as ordinary response output. Public checkpoint admission stays disabled.

Capture durable-history foundation: selective codec v24, immutable creation plus
current identity and complete ordered material history, typed capture history,
atomic result/source identity updates and `native_capture_histories: 1` reader
negotiation are implemented. Rust/Elixir validators agree on mixed synthetic
growth/capture proofs; public checkpointable-growth restrictions remain unchanged.
Memory and the PostgreSQL example pass the same captured-result contract,
including rejected-proof rollback and resource retention. A fresh BEAM safely
loads v24 vocabulary; old envelopes reject even nil new fields. Independent
pre-change encoders preserve tested HTTP/native bytes in the same BEAM process.
Public backend capture/result routing and no-clobber publication now have
implemented foundations. Embedded contexts bind the active capture snapshot,
operator policy, source receipt and exact fingerprint destination. Runtime passes
assigned pinned connections and preserves native transition metadata in the
atomic store result. Publication uses a private exclusive partial file, bounded
consumer, independent descriptor hash and directory/file identity checks, synced
file/directory metadata and a no-clobber final link. Smaller response windows bind
an optional transport chunk limit; nonempty artifact bytes bound lifetime event
count separately from unchanged ordinary limits. Models cover publication,
collisions, replaced directories, byte bounds and current-receipt preflight.
Unknown capture resolution and ordinary live/platform/package/consumer
qualification remain pending. Public checkpoint admission stays disabled.

Completed-proof resolution foundation: exact `inspect_capture` evidence now
promotes only an ephemeral source-observation context. The proof binds prior
receipt, operation/request and complete material history. Public capture resolution
uses native dispatch quiescence and coordinator serialization before version claim,
assigned inspection and guarded store resolution. Unknown results remain
`resolved_unknown` with nil artifact result and retained artifact allowance; only
source material advances. Automatic recovery keeps interrupted capture uncertainty
and does not import a recovered proof. Memory and PostgreSQL pass the same running/
stopped resolution/rollback contracts. Entered captures without completed evidence,
including retained native staging/budget resolution, and ordinary live/package/
platform/consumer qualification remain pending; checkpoint admission is disabled.

Entered-capture material resolution foundation: the shared engine now explicitly
resolves only an exact entered intent after original-source/worker quiescence,
under the same machine gate and original creation marker. A separate typed proof
records the stopped source's actual checkpoint head and unchanged remaining
material, advances the ordered journal revision and permanently retires the ID.
It has no artifact result and cannot decode as capture completion. Exact recorded
resolution lookup is read-only; repeated resolution returns existing evidence.
Seven non-VM contracts cover old/advanced heads, request/material tampering,
nonquiescent sources, live original PID, retained engine ownership, gate/marker/
budget rejection, proof/history corruption, no replay and finite independent
control admission. Resolution retains all capture staging and reservations.
Public protocol routing, distinct durable resolution histories, authenticated
staging cleanup/native allowance release and ordinary qualification remain
pending. No public checkpoint capability is enabled.

Entered-capture protocol foundation: protocol 2 now carries distinct
`resolve_capture`/`capture_resolved` and
`inspect_capture_resolution`/`capture_resolution_presence` pairs. Explicit
resolution requires `quiesced: true`; both requests have a 30-second ceiling and
checkpoint-feature gating. The helper routes the shared-engine boundary and
exact recorded lookup. Rust/Elixir validators agree on shared synthetic proofs,
reject artifact/completion substitution and bind original receipt/ID/request with
zero output. Positive resolution uses reserved control scheduling, including
modeled quarantine, without re-enabling ordinary work. The finite independent
material metadata constant agrees across engine/protocol. An in-process native
peer exercises busy workers, explicit cancellation, modeled unavailable state,
resolution/lookup and normal shutdown. This is not live crash or VM qualification.
Public coordinator integration,
authenticated staging cleanup/native allowance release and ordinary qualification
remain pending. Public checkpoint admission stays disabled.

Entered-capture durable foundation: source-only resolution is a distinct typed
material-history link, restricted to `resolved_unknown` with no artifact result.
Memory/PostgreSQL transactions bind the exact current receipt, capture intent,
full ordered history and stopped source with nil PID evidence; creation remains
immutable and retained artifact capacity stays charged. Generic capture advance
cannot import this authority. Selective codec v25 covers these histories and
attached commands, rejects older-envelope substitution and safely decodes in a
fresh BEAM. Native targets with a future checkpoint descriptor require the
`native_capture_resolutions: 1` reader before enrollment. Same-BEAM comparison
against 87fa629 preserves representative HTTP v12, native v23 and captured v24
bytes. Rust/Elixir full-history validators distinguish a recorded absent head
from unknown lineage, reject individually canonical inconsistent links and retain
capture/growth operation-ID retirement. Six new Elixir models, one Rust journal
model and 48 ordinary PostgreSQL contracts pass.
Authenticated native staging cleanup/allowance release and ordinary live/package/
platform/consumer qualification remain pending; checkpoint admission is disabled.

Public entered-resolution foundation: `Checkpoints.resolve` now invokes
native-only `qualify_capture` for present unknown native capture intents, after
authority serialization, exact owner/epoch quiescence and version claim. HTTP
continues inspecting its source, and deleted resolution never qualifies present
material. The backend observes exact completed/recorded evidence before dispatching
explicit entered-source resolution; its original absolute deadline spans all
stages. Final owned source observation precedes the atomic store write. Automatic
inspection can recover recorded resolution authority ephemerally but does not
persist it or replay capture. Protocol-2 quarantine permits only bounded control;
pinning rejects foreign health and quiescence preserves quarantine. Models cover
unknown stopped and completed-proof running sources, busy/stale/crossed guards,
absence, wrong reply kinds, native errors, retained capacity and disabled package
admission. Entered running-source resolution, authenticated staging/native
allowance release and ordinary source/package/platform/consumer qualification
remain pending. Every full-parity acceptance row remains pending.

Running entered-resolution foundation: the native engine now mints an opaque
source authority only for a fully stopped source with original-process absence or
the same enrolled live source. Successful engine-controlled forkable start
records an independent PID/birth witness, because public SDK `pid()` may fall
back to inventory. Original receipt, enrollment, SDK PID, row PID/birth and OS
liveness/birth must all match. Capture preflight and entered-source normal stop
reuse this boundary. Boot activity, dependent clones, OCI ownership, missing/
foreign cache ownership and stale PID reject. Exact live source resolution
advances only source material and conditionally updates retained handle authority;
recorded-proof recovery cannot invent enrollment. Source remains running and
artifact stays unknown. Memory/PostgreSQL/public coordinator models verify both
head outcomes and running/stopped source projections, mismatch rejection,
immutable creation, no replay and retained artifact allowance. Native staging
cleanup/allowance release and ordinary live source/package/platform/public
consumer qualification remain pending; checkpoints stay disabled.

Capture staging retention foundation: capture now publishes a protected schema-1
stage record before source intent/SDK dispatch, binding original receipt,
operation/request, private directory dev/inode and exact worker metadata digest.
Entered uncertainty transfers its actual promoted job lease to a recoverable
registry after collection, keeping every declared allowance charged. A replacement
engine restores reservations only from bounded, owner-protected, domain-bound
records. Indexed missing/redirected stages keep reservations and quarantine work;
unindexed legacy directories quarantine without adoption or deletion. Existing
pre-entry/completed cleanup removes a matching unretained registration only after
synced own-directory absence. Seven non-VM retention/identity/restore/corruption
models and ordinary native contracts pass. Explicit retained-stage cleanup/native
allowance release, its Port/public integration and ordinary live/package/platform/
consumer qualification remain pending; no checkpoint feature is activated.

Retained-stage cleanup foundation: the shared engine now exposes explicit
`cleanup_capture_staging` with positive caller quiescence, exact original
receipt/ID/request, source gate/creation marker and completed/resolved source
journal evidence. A retained collected lease and exact protected stage record
are required. Cleaning intent is persisted before descriptor-relative traversal
and root unlink; synchronized absence and private Cleaned completion precede
actual native allowance release. Repeated calls return the same path-free cleanup
receipt. Protected Cleaning records may resume partial removal or finish known
absence; completed records do not restore native reservations on replacement.
Quarantine is never cleared by cleanup. Six new non-VM models cover engine
authorization, outside links, cancellation, partial/removed-root recovery,
completion bookkeeping recovery and mismatched/uncollected stages. Typed Port
cleanup now has exact protocol-two request/reply authority, positive quiescence,
checkpoint approval and a finite zero-output control path. Validators reject
foreign intent, artifact/material-result substitution and streaming. Native peer
models exercise busy-worker and quarantined control dispatch; pinned Elixir calls
preserve quarantine. Stopped-source deletion now enrolls exact current authority
in protected collected-stage records before SDK deletion removes source journals.
Deleted-source cleanup requires that enrollment and verified absence, rejecting
unenrolled, recreated and partial sources. Registry replacement preserves the
authority/reservation; already cleaned receipts keep the same identity. Five new
non-VM models cover these boundaries and budget cancellation before SDK entry.
Prepared-stage abort now validates exact pre-entry stage and source authority,
clears only its own unentered intent, and preserves later source operations.
Distinct Aborting/Aborted records bracket descriptor cleanup and synchronized
native release; automatic pre-entry retirement retains the real lease on failure.
Both bridges validate the separate zero-output abort reply and quarantine/control
boundaries. Six native non-VM models cover exact material preservation, entered/
foreign/cancelled/gated rejection, automatic retirement, partial/known-removed
continuation, completed bookkeeping recovery and later-operation isolation.
Registered completed guards now retain their real lease through bounded source-
proof checks and descriptor closeout. Synced Cleaned receipts survive normal
registry replacement; the source journal/SDK record is untouched. A completion
flag alone cannot release native admission. Failed collection-marker updates
may qualify only through exact completed/resolved source evidence, retained
capacity and original stage identity. Three new non-VM models cover ordinary
closeout/replacement, missing source proof and substituted-root preservation/
recovery, including source-gate exclusion and continued quarantine.
Native capture acceptance now freezes the exact source receipt. Guarded Memory
and PostgreSQL release transactions require a typed, correlated cleanup receipt
and atomically persist it with released accounting; the proof is immutable and
repeated consumption is idempotent. Shared contracts cover completed/resolved,
deleted-source and aborted capture records, crossed/stale rejection and retained
usage. PostgreSQL rollback preserves both accounting and proof absence. Selective
codec v26 and `native_capture_cleanup: 1` reader/writer negotiation retain old
HTTP/v24/v25 encodings without new authority. Fresh-BEAM and same-BEAM previous-
codec comparisons cover this boundary. Public release now serializes with native
recovery, pins/quiesces the helper and claims worker/machine authority before
native-only `cleanup_capture`. Scoped requests bind original capture receipt,
approved policy and exact intent. Only a transition-free resolved capture with an
exact pre-dispatch state reply can select abort; uncertainty cannot trigger
fallback or replay. Receipt consumption follows repeated host-output absence
checks and a fresh store guard. Ten public peer models and five transport/policy
models cover success, idempotence, busy/stale/crossed/uncertain rejection, host
partial-output preservation, distinct abort replies and original deadlines.
The shared engine now separately qualifies a source after recorded pre-entry
abort. Registration retains original source intent/PID/birth before dispatch;
legacy records retain their encoding and cannot invent missing process evidence.
The distinct qualification proof preserves original material and requires actual
cache/start enrollment for running sources or verified original-process absence
for stopped sources, with source gate/domain/material/marker and before/after
checks. Six non-VM models cover proof separation, original process authority,
replacement, live-process disguise, unsafe/cancelled/gated/changed requests and
legacy rejection. Port/public/store source-qualification routing remains pending;
stage cleanup alone cannot resolve an active unknown capture. Ordinary
live/package/platform/consumer qualification remains pending; admission is disabled.

Source-scoped backend and Runtime routing foundation: native creation, explicit
held release and completed-result lookup now validate original proof plus both
positive current observations under one helper PID/epoch and absolute deadline.
The source reference preserves its complete material history; the independent
child scope cannot borrow source assignment or creation identity. Runtime consumes
paired completion and explicit kept resolution without SDK replay. Exact branch
approval/inherited metadata and a fresh-create rejection guard prevent an image
creation fallback. Future descriptor enrollment requires both native_branches:1
and managed_branches:1; current stores deliberately do not advertise the native
marker. Fifteen backend semantic models and one startup model run without a VM.
All 1,116 ordinary Elixir cases and 25 final focused cases pass; 42 runtime/deferred
cases remain excluded. Formatting, warnings-as-errors compilation, 13 runner guards
and both source-verification modes pass. Credo has the same 51 existing findings.
Rust and PostgreSQL production were unchanged; their suites were not rerun here.
Strict ExDoc generation fails on existing hidden native type references in the
unchanged Store/Volume API documentation; that check remains outstanding.
Public admission, partial/absent resolution, deletion/backing retirement, prepared
retirement history, normal replacement and ordinary SDK/platform/consumer
qualification remain incomplete. No package or crash qualification is established.

| Requirement | Current evidence and remaining work |
| --- | --- |
| P0.1 Operations, arities, specifications | Checked manifest and `backend_parity_coverage_test.exs` cover 40 operations, 46 arity signatures and eight specification features, including native-only explicit capture qualification and cleanup. Acceptance references are inventoried; implementation/qualification closure remains pending. |
| P0.2 Public HTTP restrictions | Design matrix and 15 manifest contracts record existing source/platform/input limits. Shared backend acceptance is pending. |
| P0.3 Clean SDK witnesses | `native/tests/clean-sdk-api` compile witnesses and three pure configuration/lineage tests exist. Bounded integrated feature behavior remains pending. |
| P0.4 Existing-agent commands | `native/http-parity-api-boundaries.md` and compile witnesses identify public RunConfig, mount/overlay and AgentClient APIs. Expanded command/terminal integration remains pending. |
| P0.5 Auxiliary resources | Image seeds remain disabled. Builder/export/fork enrollment, accounting and ownership integration remain pending. |
| P0.6 Feasibility blockers | Audited source/API gaps are documented. Every required row still needs an implemented clean-API/resource solution; no CLI/server/patch fallback is permitted. |
| P1.1 Shared approvals | `Runtime.Approvals`, native config and Target normalization preserve optional catalogs. Feature-gated OCI catalog selection, source-only configuration, typed assignment construction, qualification and managed MachineSpec/start translation are now present. Exact source identities and approved profiles remain separate from helper capability approval; remote_sources remains outside implemented package approval for public admission. Registry/other source catalogs and ordinary public source assignment acceptance remain pending. |
| P1.2 Versions and features | SDK/engine/protocol identities are separate. Config, Features, manifest policy, Launch and Hello bind the implemented descriptor. Additional feature predicates activate only with implemented approved capabilities. |
| P1.3 Material authority | `native/smolbox-engine/src/material.rs` binds fresh root proofs and bounded prepared/entered/completed journal transitions. Twelve deterministic tests cover uncertainty/no-replay. Descriptor-bound geometry and bounded owned SDK growth now have pure and selected ordinary non-VM checks. GrowthTransition/GrowthChange expose typed prior/next receipt, operation/request, size and immutable-configuration evidence from completed journals; Rust/Elixir share exact canonical hash fixtures and reject reordered/missing/duplicate links. Pending entries cannot supply transition proof. Full QCOW chain/filesystem verification, public increased reservations/histories and platform qualification remain pending before product growth. |
| P1.4 Assignment/history shapes | Assignment version, immutable network/port/workload intent, matching receipt and observed network/port validation exist. Retained executions preserve the original creation features through their explicit managed-machine association; absent ExecutionSpec ports/workload fields cannot replace that authority. Public execution/inspection/measurements and v17 tests cover mapped workload machines and reject altered observations. Port-bearing records preserve reservations through normal stopped replacement. Typed OCI and registry source creation identities and retained image-pull records now have strict native structural validation, exact origin matching and selective v19 storage. Registry intent retains distinct manifest/content/alias/credential-reference identity while excluding token bytes; existing OCI wire/pull predicates remain OCI-only. Memory atomic reserve/recovery and fresh-BEAM decoding pass for both kinds; v16-v18 cannot accept either source envelope. Source aliases/manifests cannot become local pack authority; native pulls require retained OCI association and preserve the original source/reservation. OCI source assignment/wire/start plumbing is now implemented behind remote_sources approval, including exact source-origin startup checks. Public activation/qualification, other source kinds, remaining optional histories, child identity, volumes and evolved resource observations remain pending. |
| P1.5 New protocol | Protocol 2.0 is selected by engine 0.2.0/manifest 3/config schema 2, from package policy through public Runtime creation/result consumption. Legacy 1.3/1.4 selection remains explicit. Terminal open/controls/output/completion schemas are activated by the explicit terminals descriptor; remaining expanded operations are pending. |
| P1.6 Durable codec | Selective v17, exact v16 preservation, fresh-BEAM decoding and material-reader startup capability exist. Native background intent/results retain existing shapes but additionally require native_background_launches reader admission before enrollment. Full-bound nil-stdin commands retain v17 shapes and require native_streaming_commands reader admission before enrollment. Native retained Terminal.Spec/Terminal.Result reuse v17 and require native_terminal_sessions reader/command-slot support before terminal descriptor enrollment. Memory/PostgreSQL example advertise these reader capabilities; older descriptors remain eligible with their original reader requirements. Native growth histories now have selective v18, typed transition/default evolution, exact legacy envelope preservation and fresh-BEAM decoding. Native disk-growth reader/atomic-store admission requires native_disk_growth: 1 plus managed_disk_expansion: 1; Memory and PostgreSQL example advertise the reader. Selective v19 now preserves typed native OCI source intent and inherited image-pull authority, rejects v16-v18 relabeling and has fresh-BEAM reader evidence. Native source/image descriptors require native_sources: 1 plus existing atomic registry/image markers before enrollment. Memory and the PostgreSQL example advertise the reader; no source capability is activated. Selective v20 now preserves native volume binding and exact provision/delete/abort proof, with identical HTTP v15 bytes, strict legacy-envelope rejection and fresh-BEAM reader evidence. Native volume reader advertisement and recovery/mount integration remain pending; no volume descriptor is activated. Other expanded histories and ordinary new-package durable consumer checks remain pending. |
| P2.1 Observations | `observations.rs`, the capped read-only SDK adapter, versioned wire schemas and `EmbeddedObservation` implement all six public operations. Tests cover public types, distinct accounting, receipt-free inventory, saved-authority measurements, bounds and normal process samples. Exact new-package Linux/macOS qualification remains pending. |
| P2.2 Jobs and gates | File subprocesses and foreground execution share engine-owned work leases; observations have a separate admission lane. Machine/source leases remain held through owned child collection, including retained uncertainty. Bounded agent I/O also supports an owned streaming-command worker with live ordered spool forwarding, absolute deadlines and distinct Exit evidence. A non-VM SDK peer proves pre-Exit delivery with a full public environment and 12-MiB output. Explicit streaming_exec wire/descriptor and native_streaming_commands reader activation now integrate this worker with the public Runtime. Owned terminal jobs now integrate private supervision and public controls. Stopped growth now shares the owned job supervisor and retains original disk descriptors through uncertain collection. Read-only measurement gates share retained machine locks without reopening work admission after quarantine. Remaining registry/artifact/auxiliary jobs, complete deadline propagation and auxiliary enrollment remain pending. |
| P2.3 Resource budgets | Negotiated job_resources binds four shared work slots, two observation slots, four worker children, 64-MiB staging, descriptor reservations and control FD headroom. Two dedicated Port observation threads and two reserved request identities preserve dispatch with all four work threads blocked and 30 work requests retained. A deterministic bridge test also blocks one observation, completes readiness on the second, explicitly cancels the observation and shuts down normally. Exhaustion rejects before dispatch; unresolved collection retains every lease and quarantines work admission. Approved protocol-2 observations remain bounded on the same authenticated live channel after quarantine; readiness remains unavailable, legacy admission stays fenced and normal collection does not restore work. Engine, Rust bridge and Elixir Channel/Port/Call contracts cover this separation. File SDK reply headers are bounded before allocator exposure. Existing compact-creation/read/inventory bounds remain. Work metadata now has an independent 32-MiB allowance, with 256-KiB reserved control metadata: two bounded volume observers remain admitted under full work metadata and quarantine. Two new contracts cover both admission orders, finite control allowance and exact release; this corrects starvation introduced by charged volume observers without changing work/command/file bounds. A future volumes descriptor now negotiates exact 256-KiB control memory and 128-KiB per-observation memory separately from job work metadata; shared Rust/Elixir fixture validation rejects changed/missing bounds, and bridge tests compare each bound with executing engine constants. Additional worker types, VMM/auxiliary counts, memory/stream budgets and broader interference/platform acceptance remain pending. |
| P2.4 Stream sinks | Existing bounded command/file forwarding remains. The separate console stream now frames complete text lines in the Port adapter, binds byte/event credit and parses fragmented lines in Elixir without changing command/file limits. The shared engine emits transport-independent text lines and reserves bounded console buffers. PTY output uses distinct byte/event credit and whole consumption without a transcript lifetime cap. Private staged export packing/upload now has a greater-than-16-MiB artifact witness with one-MiB acknowledgement credit and bounded 256-KiB file reads. Incomplete response bodies, explicit cancellation/deadlines and retained source/staging/control authority are covered. Guest/worker, capture sinks and full ordinary pipeline acceptance remain pending. |
| P2.5 Deadlines and outcomes | Existing framed peers and material models cover bounded correlation and conservative uncertainty. Expanded operation/session contracts and normal child collection remain pending. |
| P3.1 Egress | `creation_features.rs` and `Embedded.CreationFeatures` translate exact canonical allowlists into public SDK record fields, select virtio-net and validate actual receipt-bound configuration. Engine/wire/public peer tests pass; ordinary traffic and package/platform qualification remain pending. |
| P3.2 Ports | Native intent/observation, canonical publisher configuration, managed_ports negotiation and atomic shared-store reservation integration exist. Public peer tests cover offline inbound intent, conflict without allocation, retained stop/drain/replacement reservations and verified deletion release. Actual listener/traffic and worker resource qualification remain pending. |
| P3.3 Workloads | Container-only native intent resolves inherited argv/env/workdir/user before SDK reservation, binds actual metadata into material authority and uses the existing SDK startup path. Tests cover neutral default, explicit replacement, named inherited user, override merge, validation and immutable identity. Bounded long-start infrastructure and ordinary guest startup acceptance remain pending. |
| P3.4 Ordinary networking | Permitted/denied traffic, conflicts, inbound replies, restart and workload witnesses on both native platforms remain pending. |
| P4.1 Registry preparation | The shared engine now has a credential-free RegistryArtifactSource and opaque RegistryBlobDescriptor. Bounded manifest projection verifies the exact platform-manifest digest, one SDK-compatible sidecar layer, separately approved content digest, config type/digest/size and declared layer size before selecting a download. An owned bounded descriptor observation reuses exact registry endpoint/auth/deadline policy; ordinary loopback engine checks prove one pinned GET, no blob/cache/machine mutation, pre-budget rejection and retained job isolation. Owned streaming blob preparation now verifies exact bytes/length before private no-clobber publication and rehashes warm cache content with path/inode/owner/mode checks. A separate finite 32-GiB registry staging pool leaves command limits and both control slots intact. Ordinary cold/warm/corrupt-cache, bounded failed-body and explicit cancellation checks pass. RegistryCachePolicy now supplies explicit bounded retained byte/file allowances (hard ceilings 64 GiB/1024 files). A bounded private cache scan rejects unknown entries and accounts retained bytes before blob dispatch; warm entries remain available at exact limits without eviction. Engine/pure tests cover capacity rejection before blob GET and strict policy bounds. Engine.qualify_registry_blob now rehashes exact private cached content, validates bounded sidecar layout/manifest and host/source architecture, uses the public SDK pinned checksum verifier, and runs the shared bounded asset/geometry/deferred-feature checks without a second cache copy. Opaque QualifiedRegistryArtifact retains the exact origin/resources/pinned prepared file. Genuine sidecar, architecture mismatch, checksum/layout/assets, wrong-domain and deterministic reader-budget tests pass; engine isolation keeps records/handles unchanged. SDK checksum I/O can outlive observation while its owned lease remains retained. Typed CreateRegistryRequest now consumes the opaque qualified pack in Engine.create_registry_prepared, selects only its private domain cache path, validates features/resources and fresh identity, and enters the existing reserved SDK materialization/disk/record path. Versioned receipt/journal authority binds SDK source_smolmachine plus exact source_registry_ref. Deadline/cancel checks surround SDK steps; after entry errors remain uncertain and only SDK serialization is released. Pre-dispatch fixtures reject cancellation, missing template approval and crossed cache identity without row/storage/reservation mutation; pure records bind origin and preserve neutral startup. Protocol-2 PrepareArtifact/PreparedArtifact now carries exact credential-free registry source and bounded size/cache observation. remote_sources alone adds its preparation capability; Session rejects legacy/absent descriptor admission, crossed terminal identity and all streams. Helper reader/worker select exact anonymous catalog policy before Native.prepare_artifact, then the adapter calls bounded engine preparation with one remaining deadline. Elixir request/result/channel contracts and planned capability order agree, with owner source approval still gated. Engine.qualify_registry_cached now validates prepared size and cache policy/bytes/pack from an existing private cache with no registry request or missing-directory creation. RegistryCreationIntent and create_registry_cached carry one deadline through cache qualification/fresh creation; read-only inspect_registry_creation follows bounded absence gates without source/cache preparation and remains usable in quarantine. Exact size/policy/source/missing-cache and absence/partial-row tests pass. Actual materialization/extraction resource qualification, Elixir RegistryPolicy now validates explicit download/cache limits and exact credential-ref HTTPS realms; Launch derives the non-secret helper catalog only for a remote_sources descriptor. Dormant legacy catalogs remain compatible, while registry activation requires policy. Pure configuration/translation/private-realm tests pass and current descriptor activation still rejects. EmbeddedPreparation now implements gated prepare_artifact arities, exact source approval, constrained request/reply budget and typed ArtifactPreparation conversion preserving distinct manifest/content SHA-256. Corrupt/crossed/streaming results reject and native safe errors retain dispatch evidence. Coverage records the adapter implementation with parity_status pending; credential options remain rejected. RegistryIdentity/RegistryCreate now preserve strict full source/credential-reference creation identity in protocol 2. CreateRegistryPrepared carries a separate bounded prepared size through exact helper approval and the cache-only engine controller; InspectRegistryCreation routes to read-only observation and remains allowed in quarantine. Existing Create/InspectCreation capabilities are reused, compact workload payloads supported, versioned receipt completion correlated and source/ref/byte limits checked before native entry. Elixir strict request/owner/channel/compact support agrees. Public create_prepared arities now validate the original registry MachineSpec/preparation identity and positive size, dispatch CreateRegistryPrepared and decode the existing Machine/receipt result. Target resolves registry sources without worker-local paths; registry start stays on the pack lifecycle route and absence uses its typed operation. Cache-independent QualifyRegistryCreation validates intent/resources/user/template feasibility before Runtime reservation, with no download/cache mutation; actual pack checks remain in cached creation. Coverage reflects adapter support with parity pending. Credential/protected IPC and full ordinary Runtime/materialization/platform/resource/store acceptance remain pending. |
| P4.2 Credentials | Shared resolver validation exists. The engine now accepts an optional nonserializable/noncloneable RegistryIdentityCredential, bounds its token grammar and redacts Debug. An exact approved HTTPS realm is separate from source identity; explicit identity tokens reject private/loopback/link-local/unspecified registry and realm literals. Bounded token exchange sends identity only to that realm with exact pull-only scope, never to registry reads; request Authorization diagnostics are sensitive/redacted. Pure request/rotation/challenge/redaction and zero-request wrong-realm/private-source checks pass. DNS rebinding protection is not claimed. The native schema-2 helper config now accepts a strict non-secret registry catalog binding exact source/content/platform, per-download cap, coherent retained-cache policy and paired credential reference/approved realm. Config checks reject duplicate/oversized catalogs, token fields, bad ref/realm policy and mismatched cache limits before engine open. Per-operation preparation now carries a strict paired credential reference/bounded RegistryToken over the private Port pipe. Exact helper source/ref policy selects the configured realm; only the executing preparation path receives engine credentials. Native Session/Handle and Elixir Channel/Port/Call bookkeeping sanitize tokens after admission/submission; source/config/results remain secret-free and Port status diagnostics redacted. Public preparation validates scoped resolver options; cached creation validates credential options but sends no token/refetch. Protocol malformed-pair/redacted token/sanitization and bridge exact-ref/no-echo tests pass. Catalog uniqueness now includes credential reference, so anonymous/authenticated or separately scoped references for the same content do not conflict; identical transport aliases still deduplicate. Non-secret authenticated destination validation rejects private registry literals at Elixir/helper config admission. Source-only catalogs now include registry packs under the same future remote_sources/policy gate. Integrated Elixir CI passes 883 cases with 42 runtime/deferred excluded, zero cycles/clones and strict type/style checks; latest targeted admission edits pass separately. Live authenticated exchange, public Runtime rotation/end-to-end redaction qualification and package acceptance remain pending. |
| P4.3 OCI creation | Bounded platform-manifest/config verification and direct OCI storage/record creation authority now exist in the shared engine. Receipt hashes bind image and source_smolmachine without a schema change. Neutral/explicit inherited workload, reservation/marker/root proof, cancellation and imported-pack rejection have deterministic models. A bounded agent-side bootstrap worker now binds the full launch plan/deadline, pulls once and sends one detached workload request through capped public agent IPC. Distinct correlated launch acknowledgment and successful normal child collection have pure and ordinary non-VM checks; they grant no process Exit/readiness authority. Engine.start_oci_owned now connects exact-policy low-level VMM launch, existing owner enrollment, retained SDK manager, bounded bootstrap and correlated post-validation. A root-process owned thread retains launch resources through deadline/cancellation; deterministic models prove both control slots remain available and late completion cannot restore admission. CreateOci/QualifyOciCreation/InspectOciCreation/StartOci now route through protocol-2 and the native adapter with existing capability names, exact source catalog pre-entry checks, source-origin receipt verification and one remaining deadline. Elixir request/owner/channel/target/assignment translation is connected. Actual live OCI startup/normal restart and public admission remain unqualified; remote_sources package approval stays disabled. Bounded anonymous host OCI manifest/config preparation now uses an owned engine job, exact SDK-parsed references, pre-blob descriptor verification, capped bodies/token flow, one deadline and no VM/cache mutation. Ordinary loopback registry fixtures and actual engine isolation checks pass; they are not public-package/live-VM qualification. Additional auth realms/credentials, registry pack/cache preparation, public source capability activation and ordinary exact-package/platform acceptance remain pending. |
| P4.4 Machine images | Passive receipt-bound engine listing and a bounded owned image worker now exist. Header-first 2-MiB reply admission, direct bounded projection (1024 images), typed public fields and distinct collected evidence have deterministic contracts. An ordinary non-VM peer covers packed observations, discarded private metadata, invalid replies and normal collection; stopped listing does not connect or boot. Protocol-2 ListImages/Images and Elixir request/channel/reply adapters now stream the validated JSON over bounded credited file events, bind count/byte totals and preserve ImageInventory semantics. Native job leases remain held through forwarding. A private pull worker now has bounded progress/final projection, protected 4-KiB intent, exact reference/platform/configuration-digest completion and ordinary non-VM valid/packed/changed/error checks. Production engine pull dispatch now reserves resources before bounded single-row preflight, requires versioned direct OCI/network/running identity, carries one deadline through protected staging/worker collection and revalidates receipt/process identity before returning the typed image. Protocol-2 PullImage/Pulled, exact helper OCI catalog admission and scoped Elixir operation/channel/reply adapters are now connected. Pure bridge/codec tests reject absent/changed approval before native entry and bind configuration-digest success. OCI source assignment/store integration, host credential preparation, bounded bootstrap and ordinary guest acceptance remain pending. Capability approval/activation and ordinary platform acceptance remain pending. |
| P4.5 Registry acceptance | Ordinary local registry, cache, mismatch, rotation, failed preparation and restart checks remain pending. |
| P5.1 Buffered stdin | `buffered.rs`, owned command-worker metadata/output spools and compact command frames implement buffered foreground stdin through the public Runtime. Shared pool leases, monotonic worker deadlines, header-first SDK I/O, observed Exit and conservative cancellation are integrated. Public UTF-8/NUL/codec tests and a real non-VM SDK worker check for bare/image context pass. Ordinary guest/platform qualification remains pending. |
| P5.2 Background launch | `background_exec: 1` activates retained buffered-only launch through an owned bounded worker using public SDK run_background. Guest timeout/stdin remain nil; a distinct correlated Launched/PID outcome cannot substitute for Exit or file acknowledgment. Shared job/metadata leases, explicit native-background reader admission, Runtime command-slot release and v17 launch results are integrated. Public/codec/wire and ordinary non-VM SDK checks cover valid, zero/malformed, oversized and missing acknowledgments. An uncertain Runtime launch retains its command slot/reservation and is not replayed after graceful replacement. Ordinary guest/platform and full deadline/interference acceptance remain pending. |
| P5.3 Console logs | `logs: 1` activates receipt-bound console tail/follow/callback through both Backend arities and Machines.logs. The engine reads the revision-specific console path without a manager, boot or mutation lock. Owner/inode/parent checks, bounded reverse tail selection, shared work/metadata admission, line/output/deadline limits and distinct stream credit are integrated. Public/parser/native models cover empty/CRLF/partial/lossy lines, callback detachment, follow timeout/cancellation, missing/replaced files and unchanged durable accounting. Ordinary guest/platform/package and broader interference acceptance remain pending. |
| P5.4 Command/log acceptance | Buffered stdin and background launch have wire/public/SDK-peer contracts. Background acknowledgment has separate authority, reader admission and durable command-slot release. Logs have public tail/follow/callback, parser, native file, budget and wire contracts. Shared ordinary guest/deadline/interference witnesses remain pending. Full-bound nil-stdin streaming now uses its explicit exec_stream wire path; public tests preserve mapped/workload creation authority, binary callbacks, actual Exit, callback detachment and codec fidelity without buffered rerouting. Output representation compatibility and ordinary guest/package qualification remain pending. Existing legacy foreground/file paths remain covered. |
| P6.1 Terminal connection | Connection.Transport and opaque Connection state now separate the controller's semantic input/resize/output/Exit/close from HTTP Mint/TLS/WebSocket handling. HTTP cumulative encoded input charges, finite passive I/O, auth/no-redirect behavior and event order remain covered. Consumption acknowledgment returns future native credit only when output leaves the queue. A non-HTTP deterministic peer covers budget rejection, binary bytes, credit failure, valid prefixes, EOF uncertainty and ambiguous Exit. The Embedded connection now receives asynchronous bridge events through the controller mailbox, sends attach on consumer binding and requires exact collected terminal outcomes. It uses pinned owner/epoch/package binding and finite bridge call budgets. Assigned-backend invocation now uses scoped execution authority and one remaining durable deadline. Native terminal records require retained version-2 assignments and a reader-first native_terminal_sessions gate. The SDK descriptor, manifest policy and helper now advertise terminals:1 together. Public Runtime peers cover binary interaction, resizing, whole credit, valid Exit and unchanged machine accounting; Exact release-package macOS ordinary PTY and current/minimum no-Rust consumers now pass (embedded-port-http-parity-terminal-macos.json). Linux, PostgreSQL and broader resource/platform qualification remain pending. |
| P6.2 Native sessions | State, bounded SDK I/O, private worker and Engine.terminal_owned now exist. Receipt-checked image/non-forkable running context acquires machine/source/domain leases and shared reservations before verified launch. Actor enrollment precedes startup authority; controls/output bind immutable correlation and exact byte totals. Normal exact child collection plus valid End qualifies Exit; uncertainty retains every lease with quarantined admission and a bounded collector. Real non-VM peers cover worker authentication and the supervised lease/credit/Exit path. The helper now routes initialized/output/control/whole-consumption credit through its dedicated TerminalBridge and engine adapter. The Elixir connection and Port control routing now have deterministic contracts. Assigned-backend wiring and durable reader/slot models now exist; package activation and public Runtime peer contracts now pass; Exact release-package macOS ordinary PTY and current/minimum no-Rust consumers now pass (embedded-port-http-parity-terminal-macos.json). Linux, PostgreSQL and broader resource/platform qualification remain pending. |
| P6.3 Terminal bounds | Finite options and the unread-byte/1024-event window reject stale/partial/duplicate credit without a cumulative transcript cap. Worker controls and SDK input each have two pending slots. Admission reserves a child, 20 descriptors, three times total-input bytes from staging and metadata/window/relay headroom from the metadata pool; work descriptors stop at 24 so two observations remain admissible. The parent uses nonblocking bounded reads/writes, finite retirement and exact collection; unresolved collection retains all guards. The helper bridge bounds pending controls to two and private credit tickets to 64. Credit waits release the registry lock; deterministic tests retain readiness during an exhausted terminal window or input queue and retire only that session. Elixir routing bounds two pending controls per handle, reserves cancellation/credit independently, caps initial credit by the requested buffer and uses per-frame response charging without a lifetime transcript cap. Broader interference and RSS/FD/platform qualification remain pending. |
| P6.4 Durable terminal slot | Rust/Elixir contracts represent terminal open/opened, ordered attach/input/resize/close, distinct binary output and collection-qualified outcomes. Feature-bound limits and whole-event credit bound outstanding queues without the command lifetime cap. The current descriptor/package advertises terminals:1; reader admission remains required before enrollment. Dedicated helper routing is implemented with initialization before output, separate input/credit queues and private output-ticket correlation. Native Elixir connection/control routing is implemented with bounded asynchronous delivery, whole consumer credit and finite calls from the captured deadline. Version-2 retained terminal records preserve immutable assignment/material proof and reuse v17; v16/disposable native authority rejects them. NativeSupport requires native_terminal_sessions before enrollment, alongside ordinary terminal store markers at submission. Memory/PostgreSQL advertise the upgraded reader contract. Deterministic slot models release only on confirmed result, preserve unknown slot/reservation and fresh-BEAM decode the fixed vocabulary. Public Runtime peers cover duplicate open/single consumer, completed-slot release, unknown slot retention, explicit API cancellation and normal stopped replacement without reconnect/input replay. Broader durable/platform qualification remains pending. |
| P6.5 Terminal acceptance | HTTP and non-HTTP controller contracts cover consumer binding, semantic resize, cumulative/per-call input, consumption credit, binary output, bounded unread buffers and conservative Exit/EOF interpretation. Native wire/helper/connection models cover ordinary controls, initialized-before-output ordering, binary consumption credit, collection-qualified Exit, stale admission and synthetic owner loss. Explicit terminal activation and public Runtime peer contracts pass. Exact macOS ordinary PTY, binary input/output, dimensions, Exit 7, v17 slot release and current/minimum public no-Rust consumers pass in sanitized terminal-macos evidence. Linux/PostgreSQL and broader resource/interference qualification remain pending. |
| P7.1 Linux volumes | Shared engine has strict generated-ID/size intent and exact operator-policy types plus a Linux-only canonical SDK-root qualifier binding account, modes and path/descriptor identity without adoption. Protected staging/provision and bounded observations bind original authority; eight root, eight staging, nine observation and seven provision contracts pass. Deletion preflight retains root/work/volume-gate authority and excludes matching retained SDK mounts across states/modes; four SDK-record contracts pass. Native deletion records immutable intent before descriptor-relative unlink and completes only after synchronized root absence. Iterative traversal reopens verified ancestors, preserves outside link targets, rejects crossing devices, bounds entries/ancestor paths and cancellation; ten removal contracts pass. Explicit resolve_volume_deletion now requires positive caller quiescence plus native work/gate and attachment admission. It validates original entered/provision records, records resolution entry, resumes only matching backing or finishes known removed backing, and preserves original operation identity through repeated explicitly fenced partial attempts. Completed provisioning can start its first fenced cleanup after a lost acknowledgment. Seven new non-VM resolution contracts reject substitution, crossed/missing proof, attachments and cancellation; observation/startup never resume. New schema-2 staging captures a synchronized temporary backing inode in protected evidence before atomic no-replacement public rename, then writes distinct final staging evidence. Four non-VM contracts cover existing-target refusal, pre/post-rename models, prepared-proof equality and schema-1 reader compatibility. These are host filesystem/API evidence, not Linux guest/public readiness qualification. Explicit abort_volume_staging now cleans matching protected temporary or published-but-unready backing under positive caller fencing and native gate/work admission, excluding SDK attachments to either path. Abort intent/completion never publishes readiness; bounded observers require matching original proof and both paths absent. Six new non-VM contracts reject foreign/substituted/both candidates, completed provisioning, false quiescence, attachments, cancellation and crossed/missing completion. Protocol-2 Volume requests/results now carry typed generated-ID intent and distinct provision/deletion/abort/qualification authority, bound to exact action/policy/domain with no output events. Reader and worker both select immutable helper-approved volume policy; native adapter routes every action to the shared engine. Only a future approved volumes descriptor sends the operator root catalog; current admission remains disabled. Long mutation budgets preserve the caller deadline while observers retain 30 seconds. Protocol/session/catalog/ordinary peer contracts pass. Exact volume limits now declare work/observation deadlines, private record bytes, deletion entries, retained ancestor bytes and reserved/per-observation control memory. Linux-only declaration and job/buffered/compact dependencies are checked in Rust and Elixir; capability order and shared fixtures agree while current packages remain disabled. Unproved temporary material without prepared/staged identity still rejects; its cleanup, long/large-tree acceptance, Elixir request/reply and public/store integration, mounts, root setup and actual guest/replacement/mode/ownership qualification remain pending. The archived 8bf113f Linux run now passes the non-VM deletion-tree fixture including its Linux-only raw non-UTF-8 filename branch; this does not qualify guest/public volume behavior. |
| P7.2 Mounts | Shared engine VolumeMountRequest now carries exact provision proof, canonical guest target and read-only mode; opaque QualifiedVolumeMounts retains approved root/backing descriptors, actor-domain ownership and sorted volume gates. Selection reopens completed private proof, excludes all cleanup journals and projects the public SDK VmRecord mount tuple without staged/arbitrary sources. Seven ordinary non-VM fixture contracts cover strict target/set bounds, exact SDK tuple/read-only projection, crossed authority, missing proof, substitution, cleanup evidence, cancellation and gate retention. A job contract preserves both control observers under eight retained mounts, bounds descriptors/memory and refuses to stack a full creation job over mount admission. Durable VolumeAttachment now preserves key/binding/proof/target/read-only authority in immutable ManagedMachine.native_mounts; selective v21 retains pre-allocation records and tombstones while earlier envelopes omit empty defaults. Memory and the PostgreSQL example check enrollment before atomic attachment, reject mixed domains/HTTP authority, preserve exclusivity and release only matching proof. Seven deterministic contracts cover shape/correlation, mixed authority, immutable/release proof, envelope rejection, fresh-BEAM reading and Memory transactions; live PostgreSQL/native VM checks remain pending. Local/OCI/registry creation wire now carries exact volume_mounts proof/target/read-only tuples; protocol Session requires future volume capability and enrolled proof domain, and both bridges select the operator policy. Assignment/allocation now copies durable attachments and retained commands inherit that authority in selective v21. Structural record checks bind saved proof to assignment and actual observed mounts. A shared Rust/Elixir fixture covers unsigned identity, strict shape, unknown/empty/null rejection, feature/domain gates and command inheritance. Helper dispatch now forwards exact approved mount policy and proof into shared-engine qualification/material publication, with no discarded-proof fallback; current public capability admission remains disabled. Private material now stores the full mount proof set, binds its digest and exact SDK tuples to creation authority, rejects proof/path/flag substitutions and preserves mounts across growth. Local mounted creation retains its opaque handle and atomically promotes the existing lease to one full creation job while preserving two control observers. Six new non-VM tests cover material authentication, legacy encoding, growth preservation and atomic admission/drop behavior. Prepared registry and direct OCI creation now share retained-handle promotion and mounted journal publication; their deterministic pre-entry cases reject cancellation and foreign handles without reservation/storage mutation or leaked jobs. SDK configuration now projects actual mount tuples, including offline mounts and staged indicators, through strict optional protocol-2 observation fields. A shared Rust/Elixir fixture and deterministic engine/reply tests cover legacy omission, malformed/bounded/staged rejection and exact saved-authority correlation; unmounted assignments reject unexpected mounts too. Local/prepared-pack mounted startup now consumes a freshly qualified handle, matches complete saved mount proof and exact SDK tuples, rechecks current backing before entry and retains gates/descriptors through observation. Atomic promotion includes one launch child without freeing work admission; the unqualified start path rejects mounts. Deterministic pre-entry tests cover full-proof mismatch, cancellation, foreign handles, control preservation and exhausted child admission. Port now routes mounted local/OCI/prepared-registry creation and pack startup through these engine paths, selecting exact operator policy and retaining full proof. Source preparation completes before mount qualification under the original deadline, avoiding stacked admission. New non-VM source rejection, adapter conversion and framed bridge contracts cover crossed/cancelled intent, full unsigned proof preservation, exact catalog forwarding and wrong-root pre-entry rejection. OCI mounted startup now validates full saved/current mount authority, promotes one retained lease to two children and existing staging/metadata/FD demand, and defers mounted bootstrap spool/worker preparation until SDK agent readiness and parent mount FD closure. Volume gates/domain/full proof follow the supervisor through successful or unresolved collection; post-bootstrap journal/SDK mounts are verified. Five deterministic contracts cover atomic admission, exhausted staging, handoff/drop retention, deferred spool creation and exact read-only guest bindings, and the framed bridge also routes approved-policy OCI start. Buffered, owned streaming and background commands now qualify saved/current backing under exact operator policy before machine gating, recheck full proof/running authority and promote the retained lease into bounded worker/output admission. Parent mount FDs close before preparation, while proof/domain/volume gates remain with collection. Unqualified command APIs reject mounts; policy-aware Port dispatch preserves credited binary output and sibling control. Three additional deterministic contracts cover worker/output admission, missing-policy/stopped-backing pre-entry rejection and framed command forwarding. Managed terminals now share current-backing qualification, ordered volume/machine gates and retained proof/domain collection ownership, with atomic terminal/input resource admission and exact Port policy forwarding. Maximum-input/control-headroom and framed credit/input/resize/normal-close contracts pass; the core pre-entry fixture also rejects missing policy without controls/output/worker preparation. Ordinary guest/resource qualification remains pending; no mount or volume capability activates. |
| P7.3 Growth | Engine/journal growth now executes through the existing owned worker supervisor. A protected 16-KiB metadata witness binds original storage/overlay descriptors, parent identity, layout and exact targets. Only distinct correlated Grown evidence plus successful exact-child collection and parent post-geometry permits database/material-proof updates. Machine/source/domain/geometry/job leases survive unresolved collection; growth retirement closes input then retains without signals or replay. Four new pure contracts cover witness identity, typed proof, signal-free collection policy and shared admission/control headroom. Selected ordinary sparse raw/QCOW worker checks cover normal success and companion substitution before any mutation; an engine fixture covers database/material completion, immutable creation identity, pre-dispatch cancellation and duplicate rejection. An engine-owned transition API now returns correlated journal evidence only after collected SDK growth; a read-only proof observer cannot replay or adopt pending/current inventory. Shared proof contracts bind original identity, preceding receipt, exact request (including null targets), size transition and preserved immutable SDK configuration. Raw ext4 remains unchanged until normal boot. Growth admission now precedes geometry reads and the same job lease enters the worker. Bounded QCOW scans fingerprint header/L1/L2/refcount metadata and stable host length, with pointer-range/alias/flag checks, cancellation and IO/memory limits. Flat backing-chain witnesses now bind up to eight path/parent/file-version/capacity/layout entries with one reader and a shared table-IO budget. Standard L1/L2/zero/backing reads bind actual ext4 superblock bytes and capacity; pure and ordinary read-only-base worker fixtures cover preservation. Standard 16-bit refcounts now match derived metadata/data counts, sparse table indexes and copied exclusivity, using a capped charged count map and shared IO budget. Pending entries now preserve original geometry; explicit quiesced engine qualification checks entered intent, stopped SDK metadata and complete preserved targets, writes only a separately audited material proof, and cannot override retained fences or adopt legacy inventory. Distinct QualifyGrowth/GrowthQualified wire/adapter and explicit Runtime resolution now bind quiescence and prior sizes before proof publication, serialize/pin/quiesce the owner and use a local resolved preview with one remaining budget; read-only/absence paths cannot repair. Backing-source provenance/content qualification, compressed/format coverage and platform qualification remain pending; no growth capability is enabled. Protocol-2 ExpandDisks/Grown and InspectGrowth/GrowthPresence contracts now bind prior receipt, exact nullable request, operation ID, previous/target sizes and canonical transition proof. The adapter uses owned SDK growth with one deadline; bounded proof lookup is nonmutating. Runtime uses scoped pre-inspection and a validated local receipt preview for follow-up observation while durable intent remains dispatching. Matching completed-proof lookup now restores a local inspection receipt with one deadline and pinned owner/epoch. Startup validates committed current geometry or exact unresolved growth proof, then keeps active expansion history unknown and fully reserved; only explicit quiesced resolution commits it. Missing proof cannot become absence/quiescence authority. Public descriptor activation and ordinary new-package acceptance remain pending. Native expansion/current-identity integration now persists correlated transitions, validates ordered committed history, selects the current receipt for retained lifecycle/command context and rejects bare geometry resolution. Increased reservations survive uncertainty; missing history cannot become current ownership. |
| P7.4 Storage acceptance | Protected native staging/provision/delete journals bind original authority and correlated completion; non-VM models preserve uncertainty and reject automatic replay/absence adoption. Explicit caller-fenced resolution now continues matching entered deletion or starts cleanup of completed provisioning; repeated explicit attempts preserve identity and normal observers remain nonmutating. Missing completed provisioning still rejects and retains accounting. Schema-2 staging now protects backing identity before public publication and keeps schema-1 readers compatible. Protected incomplete staging now has explicit abort intent/completion and read-only proof with no ready promotion; missing prepared identity remains fenced. Elixir exact request/result contracts now bind action, generated ID/size, policy and owner domain; Port checks returned root against the operator catalog and rejects current-package volume dispatch. Shared Rust/Elixir authority fixtures preserve full unsigned inode identities. Read-only volume inspections use reconciliation/quarantine observation routing; mutation never gains this admission. Durable VolumeAuthority now preserves native binding and exact provision/delete/abort proof; VolumeOps accepts correlated native completion only, keeps uncertain reservations and preserves immutable proof linkage. Selective v20 reads/writes native volumes while HTTP v15 bytes remain identical; fresh-BEAM decoding and old-envelope rejection pass. Memory atomically checks enrollment, retains binding through tombstones and releases capacity only on proof-based completion; PostgreSQL example shares the same predicates but live native-volume PostgreSQL contracts remain pending. Scoped embedded volume context/request/reply now preserves exact saved intent, public backend path/ack shapes and known proof linkage. Startup classifies volume records separately, checks ready/tombstone proof and turns interrupted intents unknown without adoption or release; matching snapshot/CAS prevents stale recovery writes. Future enrollment additionally requires native volume reader and all callbacks. Managed provision/delete orchestration now pins the owner before intent writes, serializes with recovery, retains worker lease and consumes correlated proof under one absolute deadline. Explicit fenced cleanup alone may select staging abort after confirmed pre-dispatch ownership rejection; uncertainty cannot trigger another mutation. Native deduplication stays read-only without requiring a live helper; domain-bound fingerprints preserve HTTP inputs. Mount integration and reader activation, unproved temporary cleanup, long/large-tree acceptance, ordinary Linux guest volume/growth witnesses and macOS public rejection checks remain pending. |
| P8.1 Restore | Public portable API witnesses exist. Shared-engine ApprovedCheckpoint/ApprovedCheckpointArtifact now bind current SDK, host/guest platform, exact captured allocations, idle bare topology and forbidden workload/layer/credential/network dependencies. Classic and chunked header versions follow public SDK constants; SDK CPU compatibility remains delegated. A distinct 64-GiB checkpoint allowance preserves the public capture bound without widening pack/command/file caps. Two pure contracts cover layouts, crossed allocation/SDK/platform/device metadata and bounds. SDK convenience restore owns its own reservation/record and error cleanup, so the clean public materialize/install APIs are selected for fresh SmolBox reservation/material integration. Read-only admitted inspection now checks whole-file SHA-256, exact input descriptor/path versions, bounded footer/manifest and public descriptor-based SDK checksum/CPU compatibility. Classic streaming validation binds exact assets/digests, captured-profile expansion and the public 64-file chain bound. History envelopes bind head/ancestry/index paths and bounded content-hashed objects, but do not attest SDK index/reference semantics. Eight checkpoint contracts plus archive sizing and read-only retirement/control-isolation contracts pass. Request-private staging now retains input bytes, domain binding, separate 128-GiB aggregate staging and 128-MiB SDK-parser allowances through cleanup. Public SDK index readers and StoredFile serialization enforce exact declared files, referenced object lengths/hashes, reconstructed file digests, head/ancestor lineage and data summaries; ancestors retain their captured resource profiles. SDK-written fixtures exposed and corrected empty structural directories, top-level disk targets and the published 64-file chain limit. Unknown stage replacement is preserved with retained allowance/work fencing in a non-VM model. Public SDK extraction/uncached store materialization now runs in the owned job worker with four chunk threads, a fixed system tool path and a reserved SDK CPU-query child. Its distinct acknowledgement binds exact metadata/source hashes and output identity/inventory/version evidence; no generic or retired acknowledgement promotes a materialized input. Atomic promotion retains one work slot and separate decoded staging through collection; the source lease remains charged until cleanup. A rebuilt macOS debug helper ordinarily materializes both SDK-written layouts, verifies bytes/proof, collects normally and leaves no SDK VM row. No VM is started by this evidence. Fresh creation/installation now binds generated owner/incarnation, selected material and no-clobber ticket to a private SDK VM directory after SDK-name reservation. The owned install worker uses public install/discard APIs, checks input/output top disk capacities and pending inputs, and emits distinct correlated installation evidence. Parent rechecks precede public neutral bare record construction, creation receipt and material-journal publication. Source, machine gate, SDK reservation and separately charged installation work survive unresolved collection; errors keep partial storage without replay. An ordinary macOS non-VM fixture installs sparse disks, commits a receipt-bound stopped row, leaves no VMM PID and releases native leases after collection. First-start now uses an immutable-root-hash/receipt-bound private pending/entered/consumed journal. Pending installed versions are anchored after authorized macOS staging-link cleanup while source capacity, SDK reservation and gate remain held. Entry is persisted before SDK start; completion requires SDK success, actual enrolled live PID/birth and SDK-consumed inputs. Entered observation stays IdentityUnknown and cannot supply replay or cold-boot authority. Same-engine normal stop is allowed only with enrolled handle and matching live PID/birth; it does not resolve the entered operation. Five deterministic contracts cover missing/crossed/consumed/entered/cancelled/replaced state plus legacy behavior. The ordinary SDK-created non-VM fixture verifies pending and entered classification/start rejection. Explicit quiesced resolution, expanded saved-state durable/wire histories, large-history scalability and ordinary restored-VM/platform/consumer qualification remain pending. No restored VM or existing-machine ownership is produced. |
| P8.2 Capture | Checkpointable creation/start/preflight, shared engine capture/owned SDK worker, Port streaming, scoped backend routing and native publication/history are implemented foundations. Exact request/proof/current receipt, byte/identity checks, bounded transport/consumer, synced no-clobber publication and atomic durable history have deterministic contracts. Explicit unknown-result resolution and exact-package ordinary running-source/platform/consumer qualification remain pending; public checkpoint admission is disabled. |
| P8.3 Export | Shared-engine stopped-source admission now retains exact receipt/material, source gate, root FD/domain identity, absolute cancellation/deadline and work allowance; bounded dependency projection supplies no ownership. Bare disk preparation now retains both raw/QCOW descriptor views, atomically promotes FD admission and streams exact logical data/digests without helper boot or CLI conversion. Protected raw materialization now owns sparse output, a separate aggregate byte allowance, source/request-bound registration, file versions and explicit cleanup; modeled reopening restores capacity without adopting output. Bare pack construction now consumes materialized disks and exact operator-approved runtime asset files, uses bounded single-thread tar/zstd with public SDK manifest/footer types, independently verifies whole-file identity and records Packed staging authority. Fresh staging schema 2 permits packing; schema-1 rows retain read/cleanup compatibility. Source gates and byte/work capacity survive through explicit disposal, and partial packs cannot replay or become publication evidence. SDK format-reader checks and synthetic assets do not qualify package bootability. Package setup now derives a rootfs tar and exact library grants from the verified manifest, installs an immutable package/domain/root-bound catalog under native admission and selects it through the public Rust packing method. Packages without a tar retain catalog omission. Ordinary rebuilt macOS package preflight and archive-to-manifest file/link checks pass without an engine or VM; this does not qualify guest boot or export/import. Native one-attempt publication now uses SDK OCI types, bounded local HTTP transport, distinct transient push bearer, source postcondition checks and protected schema-3 prepared/entered/completed evidence. Local peers cover vacancy, range/byte fidelity, no auth/redirect/retry, cancellation and uncertain results; exact recorded completion can be inspected without registry-result adoption. Source/work/scratch remain held through explicit disposal. Gated protocol-2 preflight/publication/lookup/cleanup now select exact cached operator destination/TLS approvals without reader I/O. Typed Rust/Elixir replies require zero output, canonical publication hash, original receipt/operation/request/destination/tag/size and package-platform correlation; scoped tokens are removed from retained bookkeeping. Reserved control lookup/cleanup works under occupied work lanes and needs no current destination catalog. Shared synthetic fixtures validate actual engine/wire/Elixir proof correspondence and exact executing limits. Native export history now freezes enrolled source authority at acceptance and the bounded request before dispatch. Selective v28 retains correlated acknowledgement and separate cleanup proof; source history/platform and independently verified config/content identity remain exact. Memory and PostgreSQL share guarded unknown-reservation/cleanup-release contracts; HTTP v11 defaults/bytes and earlier native envelopes remain compatible. Future enrollment requires native_export_histories: 1. A deterministic ordinary startup peer classifies interrupted export as unknown without publication/cleanup replay or proof import. Scoped managed qualification/publication now use the same pinned helper and freeze an exact source-sized staging/artifact request selected from cached destination identity/caps. Exact native acknowledgement lookup precedes the existing independent registry verifier. Explicit public resolution serializes/quiesces the pinned helper, consumes separate cleanup, observes disposition and rejects changed intent or an exhausted shared control deadline before release. Typed backend and public Memory models cover zero-output/correlation, result uncertainty, busy/stale epochs, invalid cleanup and accounting; HTTP export/registry contracts preserve retry behavior. Explicit live-source no-stage retirement now authenticates marker/current material under the source gate, rejects unindexed/crossed roots and writes protected schema-4 zero-byte authority in a separate proof domain. It prevents replay and grants no publication or VM absence; exact protected cache lag/reopen retain the same fence. The existing separate 32-MiB material-control allowance preserves cleanup under full work/FD/metadata admission and quarantine without clearing it. Registered stage authority is independent of VM-row lifetime; a private removed-source model verifies cleanup. Separate bounded admit_export now records protected schema-5 frozen source/request identity and ceiling before managed dispatch, while qualification stays read-only. Dormant admission uses no scratch allowance; exact materialization records Entering before creating a directory and consumes admission once. Explicit cleanup retires admitted authority after private modeled source removal without granting publication, absence or replay. An unproved Entering directory remains fenced with its allowance. Native session/bridge and Elixir wire/backend contracts cover feature/catalog/deadline/zero-output boundaries; the ordinary two-GiB format test exercises admitted packing. Registry-container source preparation now holds receipt-bound stopped source/storage descriptors and its original gate/deadline; bounded cached metadata produces an inert exact-digest/native-platform plan. FlattenLayers follows actual agent topmost-first precedence and streams without a guest output path. SDK manifest seeding preserves env/user/command/workdir/resource semantics, with source-record binding and bounded output. Four non-VM models cover semantics, malformed/crossed metadata, changed disk, cancellation and substituted owner. These inputs grant no helper, cached-image authenticity, layer-production or publication proof. Operator conversion resources now flow through an optional strict catalog grant, with legacy omission preserving bare behavior. Engine budget plans bound guest CPU/memory and count raw helper storage, root overlay/COW metadata allowance, source COW view, flattened tar and final artifact against the same staging/disk grant. Prepared container inputs freeze the selected plan and atomically promote their original job to two children/24 descriptors without double charging or consuming control headroom. Pure models cover underfunded/invalid/changed grants, exhausted children and quarantine; no helper is launched. Schema-6 pre-launch helper scratch now binds original export admission, deterministic namespace name, exact conversion resources/budget and private directory device/inode/UID/timestamps before any SDK entry. The held scratch handle retains source/job/directory authority and rejects SDK process-cache mismatch; private models invoke no lifecycle API. Explicit protected Removing/Removed transitions retire only empty matching helper roots, bind a distinct cleanup hash and support recorded removal/cache-lag reconciliation after source-row disposal. Foreign/substituted roots and unproved absence retain capacity. Schema 6 grants no SDK dispatch, Ready/Packed writer or publication authority; schemas 1-5 retain compatibility. Schema-7 owned storage-only SDK initialization now checks original source/disk, VM namespace, package templates/host context and exact SDK library selection, then records SdkPreparing before public sparse-disk/private-COW APIs. The executing closure retains the original leases after observation retirement; returned batches record bounded exact private file versions as SdkPrepared even after partial failure, without a late success or VMM claim. Explicit version-bound cleanup supports recorded removal prefixes and protected/cache completion recovery only. Private tests exercise SDK sparse disks at explicit fixture paths, partial/uncollected/substituted files and namespace mismatch; they do not qualify full SDK namespace/COW/library execution. Schemas 1-6 preserve previous hashes and semantics. Boot finalization now yields a nonconstructible original-operation/machine/epoch/child enrollment after SDK return, including after normal child exit; exact PID substitution remains fenced. OCI startup records its original enrolled birth instead of resampling PID inventory after return. This establishes a shared child-evidence primitive, not helper launch or current-liveness proof. Initialized SDK storage is now retained in a bounded engine-owned registry before caller deadline collection. Dropping its observation token releases no source/job/descriptor/disk authority; exact successful quiesced cleanup alone removes the entry. Live borrowing, changed request, contention, cancellation or filesystem uncertainty retain ownership and capacity. Domain/registry substitution rejects; normal replacement restores staging capacity/quarantine without adopting tokens or storage objects. Private storage models prove those boundaries without SDK manager construction or VMM launch. A retained token can now prepare and retain an unstarted SDK manager with an explicit package rootfs anchor and reopened exact collected disk handles. Namespace, source/files, manager name/own-child absence and disk paths recheck before/after; repeat preparation rechecks the retained manager and failure preserves storage leases/cleanup. Explicit rootfs selection avoids default/cache extraction and rejects host redirects, while SDK guest init links remain valid. Two private boundary tests prove those checks, not positive full manager or guest boot qualification. Schema 7 still grants no launch. Manager preparation now retains a descriptor-checked private source COW and exact protected resource/configuration inputs; immediate source path/version, logical size, complete helper files/name/raw lengths and frozen grant must match. Partial batches remain cleanable. Four private models plus an exact-selected ordinary SDK filesystem-only raw/QCOW overlay witness pass; no manager or VMM is started by that witness. The retained token now connects one root-process SDK launch with the original budget and source leases. Per-entry work locks preserve registry control access; schema 8 freezes entered boot intent and exact returned pre-exec child enrollment, including creator and epoch-directory identity. Returned dispatch grants no child collection or cleanup proof; reopening restores capacity/quarantine without adoption. Private record/control models pass; positive helper startup is unqualified. Original SDK enrollment is now retained separately from returned-record publication. Explicit retained/retired collection controls use an owned bounded thread, original manager PID/birth and actor ledger even under launch quarantine. Opaque child collection is recorded in schema-8 collecting/collected phases without granting fsync, files, export or cleanup proof; all four phases restore capacity/quarantine on normal reopen. Ordinary non-VM child exit and private collection/control models pass; SDK helper shutdown remains unqualified. Collection now enrolls schema-9 post-launch runtime custody only from original opaque collection. Exact bounded regular/socket snapshots and the held rootfs helper marker bind removal; unknown/changed inventory rejects, protected Removing permits only captured remaining files, and a distinct hash binds successful retirement before allowance/source release. Marker-present/absent, substitution/type/size and partial-removal normal-reopen models pass; actual SDK inventory/rootfs behavior remains unqualified. Isolated-worker layer I/O now streams the SDK canonical sixteen-MiB DataChunk envelopes through bounded buffers with original deadline/cancellation and terminal byte/hash evidence. SDK-encoded large/fragmented loopback, invalid/missing/error/cap/base64, cancellation and pre-entry spool/path cases pass; no source, worker collection, tar or publication authority is granted. Frozen source/resource/deadline worker input now connects fixed private-source mount and cache bind commands, bounded exact digest/platform cached query and the existing topmost-first plan directly into streamed layer I/O. Typed header-capped query decoding avoids an unbounded Value tree and duplicate image parse; no pull/rebase/credential or arbitrary command is added. Setup/missing/foreign/cap/empty/pre-entry loopback cases pass without a VM. The original retained entry now dispatches one isolated conversion worker without another work reservation. Exact input/terminal evidence and distinct bounded layer/plan spools stay retained through actual child collection; parent rehash and source/plan checks precede an opaque bounded-read handle. A worker/output lease fences helper collection and cleanup, including retired callers. Generic/forged/retired evidence and pre-entry spool substitutions reject in non-VM contracts. Protected schema 10 now binds entered/ready layer custody to input/plan hashes and original file identity/bytes/hash. The original-entry opaque output moves by descriptor-relative nonreplacement rename, without a second tar allocation; post-move rehash/read-only mode precede ready registration. Plan metadata stays retained for packing. Helper collection/runtime retirement preserves schema 10; changed/unknown inventory retains capacity and private incomplete-handoff/reopen models permit cleanup without writer or VM adoption. Packing requires original opaque collection, then explicit helper retirement. Schema 11 now binds readiness, bounded packing intent, writer entry and the original empty output inode before body writes; unsupported schema/state combinations reject before mutation. The shared bounded packer emits SDK container mode with one digest-named layer, approved assets and inherited metadata; SDK footer/checksum/archive tests pass. Generic packed forwarding/publication/cleanup retains the original container entry, with a strong lease across normal Engine value drop. Private registry peers prove one-attempt publication and cleanup without releasing staging early. Partial/replaced/unregistered output models preserve uncertainty and cleanup ownership; normal reopen grants cleanup only. These format/ledger/lease models do not qualify SDK helper production or guest import. A transport-independent engine coordinator now chooses actual source mode and sequences the owned container pipeline through existing publication; the Port adapter delegates it. Cached exact destination grants construct upper-bound requests without mode guesses, with legacy request bytes preserved. Bare logical geometry and actual container layer bytes determine effective caps. Explicit shared output budgets bound helper/tar/artifact aggregate usage without an arbitrary partition; old fixed budgets omit the marker unchanged and older readers reject it before acting. Quiesced cleanup can collect only an original retired manager, skips SDK replay after recorded collection/runtime custody and permits provably unentered storage cleanup; active callers/workers reject. Read-only/pre-entry, shared-cap/reopen, high-level storage cleanup and database-only namespace-rejection models pass without SDK lifecycle entry. Whole-pipeline output-credit validation, ordinary initializer/library/COW/rootfs/UID/mount/device qualification, ordinary local/imported guest/cache semantics and public registry export/import qualification remain pending. Controller/file models do not establish helper production of every witness. Export preserves opaque bytes while growth retains ext4 validation. Coordinator inspection/publication use assigned references and verification selects SDK version. Public native export admission, ordinary auxiliary/helper and source semantics, full managed publication/cleanup acceptance and platform/consumer qualification remain pending. Private fixture conversion is not product evidence. |
| P8.4 Branches | Public held-fork APIs are identified. Initial read-only admission now retains an originally enrolled running unbranched source and fresh child under stable ordered gates, with post-lock material/root/PID/absence rechecks. Exact public child-plus-extra resource planning has six shared Rust/Elixir cases; source/child/hold/policy/PID/birth/epoch/SDK/shared-RAM inputs bind its digest. Finite work metadata/FD admission leaves both control observers available. The original opaque guard now persists a protected prepared-only source/child declaration in the existing material journal. Exact plan/identity/PID/epoch/request validation, mutual exclusion with growth/capture and operation-ID history checks fence mutation across normal reopen. Explicit original-guard abort now persists a distinct retirement receipt while keeping source material/head unchanged. Read-only lookup can recover a lost acknowledgement; explicit quiesced cleanup also supports a normal stopped-owner replacement, with positive original-process absence or current enrolled-running authority, ordered gates and child exclusion. Completed lookup precedes current-state checks without mutation. Protected retirements anchor exact historical heads, reject cross-operation ID reuse/reordering and share the finite history budget. Four additional non-VM models cover replacement/result replay, live-original rejection, control admission, identity/source/child fencing, historical receipt lookup and corruption/history bounds; they perform no VM or forced-loss campaign. Public retirement integration and ordinary source/platform qualification remain pending. Bounded private fork-preparation worker/IPC and an opaque unentered producer now retain original admission, owner/source/root/database identities and one absolute deadline. Resource promotion uses two child slots, 24 work descriptors, 80 KiB of IPC staging and existing saved-state metadata allowance while preserving both observers. The worker requires a distinct protected entered grant, checks exact clean-SDK continuing-source/held no-PID child projections and returns a separate correlated proof. The original engine registry now retains the actual shared SDK runtime, source/child gates, input/output spools and admitted backing independently of caller lifetime. The protected entered writer precedes exactly one private SDK preparation dispatch. Parent collection independently rehashes original metadata/result inodes, checks bounded source/child material and snapshot identity, and requires original live-source enrollment plus exactly its prepared child dependency. Prepared abort/replay reject entered or collected work; entered registry teardown retains original authority. Explicit quiesced prepared retirement can clean a retired caller, including known completed proof after lost acknowledgement without another journal write. Computed child-plus-minimum-extra disk backing shares the existing finite saved-state material allowance; this does not replace persistent public dual reservation or host quotas. The exact ordinary non-VM rejection fixture collects normally with original leases and unchanged private database; it proves no SDK fork or live enrollment. Five non-VM retention/output/retirement models and backing admission contracts cover these boundaries without live SDK dispatch. Explicit native material publication now synchronizes its exact plan before any child identity write, derives independent child owner/incarnation plus a source/intent/raw-child/generation binding, atomically publishes a no-replacement marker and initializes the bound child root journal. Source completion requires those actual child files and original running source authority. Its distinct branch transition preserves the immutable creation fingerprint and advances the ordered head even for a macOS material no-op. Mixed growth/capture/resolution/retirement history validates immutable/head linkage and globally unique operation IDs. Exact completed lookup never replays SDK or journal mutation. Four non-VM models cover independent identity, staged publication, retry/lookup, corruption, marker substitution and mixed history; no VMM or live persistence interruption is used. Both gates, snapshot, runtime and backing stay retained. Native explicit first boot and protected original enrollment now have a retained-manager foundation and seven non-VM models, as described above. Native bounded guest initialization now has a protected single-entry/IdentityReady foundation with seven non-VM contracts. Original-job automatic/explicit release now has a protected typed-agent/material foundation with seven non-VM models, as described above. Original manager handoff and held initialization now have a native foundation with retained backing and seven non-VM models, as described above. Actual SDK boot/initialization/release/handoff/restart qualification, later fresh-budget public release/deletion, backing retirement, public codec/history/dual-reservation integration and entered resolution remain pending. The material receipt is not a public ready result or positive live-source qualification. Older prepared-only same-owner declarations remain readable/retirable; new admission/publication requires distinct ownership. Shared mode must be frozen/qualified before fork; paged raw-fork guardians are excluded. The engine now publishes authorized source-lineage changes and independent child material through its retained original context. Initial guarded native admission now freezes independent child assignment/ownership and exact source/public request/policy authority, with ordinary-child plus extra reservations in the existing Memory two-record transaction. Unknown dispatch retains capacity and source lock; accepted-only cancellation retires the index atomically. Source publication history is append-only and reaches the material head/attached commands. Selective v30 and a fresh BEAM reader preserve authority while older records retain their bytes. Guarded completion and explicit kept resolution now atomically retain the original proof, positive current source/child observations, source publication, independent immutable child root and exact held/released material. Requests/completion stay immutable and backing remains charged. The shared synthetic contracts pass Memory and encrypted PostgreSQL, including source/child/projection rollback. Child commands retain v30 authority; source commands with branch links retain v29. Held-release store transactions now freeze a distinct version/request/deadline, current source head and both original PIDs; both adapters lock and update the pair with retained backing. Exact explicit proof/current observations complete or explicitly resolve uncertainty. Selective v31 and fresh-BEAM reading preserve prior v30 bytes; sibling-head/exclusion and paired rollback models pass. Checked engine release now binds the full original held completion before work. Reserved result qualification uses only original context, both protected completions and collected work, promoting an existing handle and retiring transient work without SDK replay, re-enrollment or backing release. Typed release/qualification requests and distinct zero-output proof replies now traverse Port with exact catalog/domain/platform correlation and bounded control storage; shared synthetic platform/hash and helper lane/output models pass. Source-scoped backend and Runtime routing now collect exact proof plus fresh source/child observations under one pinned owner and absolute budget, then consume paired creation/release completion or explicit kept-resolution transactions. Native child assignment approval checks exact inherited metadata and original policy separately; ordinary fresh-create/inspect-creation routes reject this assignment. Future native descriptor startup requires native_branches:1 plus managed_branches:1, which current stores do not advertise. Public activation, partial/absent resolution, deletion/backing transactions, child epoch enrollment and ordinary SDK/platform/source independence/cleanup acceptance remain pending. Public native branch capability admission stays disabled. |
| P8.5 Saved-state histories | Typed branch source-publication/child-release links and mixed growth/capture/resolution chains now have cross-reader synthetic fixtures and selective v29 attached-command codec support. Frozen native branch authority, initial guarded dual-reservation admission and append-only source histories now use selective v30; attached commands with branch links retain v29. Accepted-only cancellation, stale guards, retained uncertainty, old-envelope rejection and fresh-BEAM reading have deterministic contracts. Guarded completion and explicit positive kept resolution now bind original completion, current source/child observations and immutable child root/current release history in Memory/PostgreSQL. Requests and recorded completion cannot change, and rollback preserves both records/accounting. Explicit release intent/proof and attached commands now use selective v31, preserving original completion/root and earlier bytes. Memory/PostgreSQL paired release and explicit unknown-resolution models retain source lock and all backing; fresh-BEAM decoding and intent/result rollback pass. Checked engine dispatch and bounded original-result qualification now have typed Port/Elixir contracts; missing proof confers neither readiness nor replay authority. The source-scoped backend now obtains original creation/release proof and both positive current observations with one owner/deadline; Runtime atomically consumes completion and explicit kept resolution. Missing completion never authorizes replay or absence. Partial/absent resolution, deletion/backing transactions, prepared-retirement history, complete partial/lost-result contracts and public activation remain pending. |
| P8.6 Saved-state acceptance | Ordinary restore/export/import/branch independence and dependency cleanup remain pending for every supported combination. |
| P9.1 Matrix closure | All full-parity rows remain pending; checked inventory prevents a premature completion claim. |
| P9.2 Regressions | Appropriate ordinary Rust/Elixir/schema/codec/source checks run incrementally. Full expanded Memory/PostgreSQL/HTTP and resource acceptance remains pending. |
| P9.3 Packages/consumers | Engine 0.2.0 packages have not inherited old evidence. A rebuilt optimized macOS 0.2.0 package passes ordinary public lifecycle/PTY plus current and minimum no-Rust consumers. The same archive passes HTTP-only current/minimum consumers without native assets. The exact rebuilt Linux 0.2.0 package now passes raw Port ordinary lifecycle, resource/file retention, stopped-helper replacement and three normal child-reaping witnesses; see docs/evidence/embedded-port-http-parity-linux-lifecycle.json. Public current/minimum Linux consumers, PostgreSQL and remaining feature campaigns remain pending; no historical evidence is transferred. |
| P9.4 Replacement/upgrades | Deterministic public Runtime tests preserve full v17 receipt/reservation after graceful stopped replacement and lease expiry. Ordinary native/durable expanded-history and compatible-package upgrade campaigns remain pending. |
| P9.5 Public documentation | Setup/protocol guides describe protocol-2 activation, optional descriptor approval, observations, reader-first upgrade and current restrictions. Expanded examples, feature guides and final evidence remain pending. |
| P9.6 Deferred campaigns | Ordinary package selection preserves explicit versions and graceful-only collection. Thirteen older native fixture-owner/helper-loss and persistence-boundary tests now carry an independent deferred_crash tag, excluded alongside runtime by default. Dummy health peers close by message instead of forced termination. Static runner contracts enforce these tags and separate runtime selection. No deferred live crash/persistence/CLI race campaign is authorized; broader qualification-runner closure remains pending. |

## Protocol-2 activation evidence

`test/unit/embedded_package_activation_test.exs` checks compiled policy agreement,
package/config selection, rejection of mismatched SDK/policy/identity, exact Hello
approval, material-reader startup gating, refusal to promote legacy intent or
dispatch a stripped receipt, and graceful stopped Runtime replacement with a
surviving Memory store. It preserves the full receipt/reservation, waits for the
old durable lease, verifies one create attempt and performs normal deletion.

`test/unit/embedded_runtime_test.exs` runs the same public retained
creation/command/file/drain/resume contract against deterministic protocols 1.3,
1.4 and 2.0. Legacy records encode as v16 and new assignments as v17. These peers
never open an SDK database or boot a VM. Native package/config policy tests and
`native/tests/test_ordinary_runner.py` additionally reject protocol relabeling and
incompatible upgrades without launching an owner.

The progress record provides exact check counts and commit checkpoints. Raw
logs remain private under `.local/http-parity/`; synthetic fixtures contain no
real ownership receipts. This audit cannot be changed to complete until every
required matrix row and every phase exit gate has current direct evidence.
