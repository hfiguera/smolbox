# Implementation plan for embedded Port HTTP parity

Status: implementation in progress, October 15, 2026. Implements the
[HTTP-parity design](embedded-port-http-parity.md) on
`embedded-port-design-non-upstream-patches`. This document does not enable new
features. P0 coverage/API witnesses and part of P1's shared approvals/version
foundation are implemented. Engine 0.2.0/manifest 3 now activates protocol 2.0,
journal-bound fresh creation and selective v17 assignments through the public
Runtime. Bounded observations and P3 creation-intent/record translation now have
deterministic contracts. Long jobs, expanded operations/histories and ordinary
feature/package qualification remain pending;
P1 is not complete. The [completion audit](embedded-port-http-parity-completion-audit.md)
tracks requirements without transferring historical evidence. The completed
unmodified-SDK offline milestone and its exact evidence
remain unchanged. Crash validation stays deferred throughout every phase.

Deliver small coherent commits on this branch, without a `codex/` branch prefix.
Do not push or publish as part of implementation. Use verified unmodified SDK
inputs, preserve HTTP behavior and keep research checkouts read-only. Rustler is
a future bridge to the same engine; Kubernetes is a future independent backend.

## P0 Establish the parity contract and feasibility

Primary areas: `lib/smolbox/backend.ex`, `backend/http.ex`, `client.ex`,
`branch_client.ex`, public feature guides, verified SDK source, native API witnesses
and `native/clean-sdk-api-boundaries.md`.

1. Inventory every `Backend.operations/0` operation and arity and every shared
   specification feature. Turn the design matrix into a checked coverage manifest
   with HTTP eligibility, Port status, supported platform/source combinations and
   acceptance-test references. Include health/metrics, logs, volume operations,
   optional arguments and native-only qualification/absence.
2. Define public parity from the current HTTP behavior, not from upstream server
   endpoints. Preserve buffered-only stdin, retained-image background/PTY limits,
   Linux volumes, stopped growth, bare/offline saved-state restrictions and
   registry credential boundaries. Record existing HTTP unqualified combinations.
3. Add small compile/non-VM API witnesses for egress, mapped ports, workloads,
   buffered stdin, launch evidence, channel-driven PTY/resize, image preparation,
   checkpoint capture/restore, stopped disk growth, export and held branch release.
   Inspect actual buffers, spawn paths and locking as well as API signatures.
4. Resolve the SDK private `command_run_config`/`command_client` gap without
   copying uncontrolled convenience behavior. Prove receipt-bound existing-agent
   access and correct persistent overlay/user/mount selection through public APIs.
5. Record the feasibility of hidden OCI builders/seeds, export flattening VMs and
   forked children against owner epoch enrollment and auxiliary resource budgets.
   Keep image seeds disabled until proved. Never bypass the guard for a witness.
6. For each infeasible row, name the exact missing behavior/API and investigate
   callable clean APIs or a separately verified official unmodified SDK upgrade.
   Do not patch source, substitute a CLI/server or call a blocker completed.

Exit gate: complete checked feature/arity coverage and a documented API/resource/
ownership approach for every row, with unresolved blockers explicitly pending.
Ordinary live feasibility runs, if necessary, use approved disposable owned
domains and normal API shutdown only; no crash campaign is authorized.

## P1 Shared approval, versions and expanded native authority

Primary areas: `Embedded.Config`, `Backend.Assignment`, `EmbeddedContext`,
`Runtime.Target`, `WorkerConfig`, feature coordinators, store/codec validators,
Rust engine identity and native package/protocol policy.

1. Extract shared approval predicates for profiles, sources, checkpoints, export
   destinations, capture/branch policies and volumes. Add matching native config
   fields and source-only catalogs; retain distinct HTTP endpoint and native
   package/domain checks. Carry catalogs through target normalization.
2. Separate SDK version from engine/package/protocol version. Replace native
   eligibility dependence on HTTP runtime-version strings with explicit negotiated
   feature predicates; preserve legacy HTTP gates and checkpoint SDK matching.
3. Specify and implement versioned immutable creation authority and authorized
   material transitions. Bind old proof, operation ID, request, SDK result and
   verified postcondition; retain bounded native operation evidence for observation
   after a lost response. Never mint ownership from current rows or labels.
4. Extend assignment/record validation for typed optional histories, source kinds,
   native child identity, volumes, ports and material evolution. Preserve immutable
   creation fingerprints, dependency relationships and unknown reservations.
5. Introduce a new protocol major with explicit operation/session/capability/limit
   schemas; update package policy, manifests, Hello, Elixir/Rust decoders and
   fixtures together. Keep the explicit approved legacy 1.3/1.4 path separate.
6. Add selective codec evolution only if required by expanded shapes. Preserve
   v16/all HTTP readers; require reader-first upgrade and reject unsupported new
   records before mutation. Update Memory and PostgreSQL capability contracts and
   migrations together where required. Test no automatic old-receipt adoption.

Exit gate: approval, scheduling, persisted authority and wire versions can
represent the entire parity scope without enabling unimplemented capabilities.
Deterministic contracts cover changed material, lost proof, old readers, foreign
inventory, stale epochs, duplicate owners and both store adapters.

## P2 Observability and bounded job infrastructure

Primary areas: engine observations/host context, `sdk_compat`, worker supervisor,
Port runtime/outbox/session, `Embedded.Health`, backend request/reply adapters.

1. Implement bounded health/capacity/metrics/readiness/list/measurements results
   through existing public types. Distinguish SDK/engine versions, configured
   capacity, reservations and measured usage. Inventory never confers authority.
   No observation may initialize, repair, reconcile or reap SDK state.
2. Generalize owned worker/job supervision without creating another domain owner
   or implicit VM boot. Keep stable machine/source/child gate order and avoid
   double-acquiring SDK lifecycle flocks. Preserve direct child identity/collection.
3. Budget work slots, control slots, FD/process counts, queue bytes and aggregate
   staging. Sessions consume work capacity while control remains available.
   Model exhausted admission and unresolved collection; retain leases/capacity.
4. Add distinct bounded stream sinks for large capture/export artifacts, console
   logs and PTY bytes. Keep command/file caps; use policy-specific total artifact
   caps, bounded chunks, incremental hashes and whole-pipeline byte/event credit.
5. Maintain one absolute deadline through all stages and one terminal outcome per
   operation. Cover fragmented frames, malformed/late/duplicate messages, sibling
   isolation, stopped consumers and uncertain acknowledgment in deterministic
   peers; use normal children only for collection checks.

Exit gate: bounded transport-neutral jobs and truthful observations are usable
without widening existing command/file limits or starving control operations.

## P3 Networking, mapped ports and startup workloads

Primary areas: native creation/resources/material proofs, `MachineSpec`/`Profile`,
port ownership/store codec, target assignment and public retained-machine example.

1. Support exact host/CIDR network policies through clean SDK fields/APIs. Validate
   resulting backend/allowlists, existing infrastructure exceptions and package-
   approved host configuration. Offline remains default; never add destinations.
2. Support retained TCP mappings with store `managed_ports` negotiation and atomic
   `{target_id, host_port}` reservations. Prove offline-plus-inbound forwarding
   uses a network device with explicitly empty outbound lists. Keep reservations
   through stop, unknown outcomes and normal restart until verified deletion.
3. Implement workload creation via public SDK APIs and exact existing inheritance,
   argv/env/workdir/user and `restart: :never` semantics. No shell, automatic restart
   or application readiness inference. No explicit workload remains neutral boot.
4. Exercise permitted/denied guest traffic using approved ordinary local services,
   port conflict rollback, inbound replies, normal stop/start and observed startup
   behavior. Keep HTTP network/port/workload contracts passing. Record both native
   platforms' exact supported observations and owned cleanup.

Exit gate: network/workload specifications work through unchanged public managed
APIs with equal approvals and accounting, including offline-with-ports behavior.

## P4 Registry sources, OCI creation and image operations

Fresh-disk sizing note: OCI and imported container creation format the one-GiB
baseline before making owned copies writable and growing through public SDK APIs.
Exact requested sizes are verified before receipt minting. This avoids SDK
format-time expansion after read-only template copying; it does not alter VM-pack
seeding or qualify guest filesystem growth. An explicitly opt-in disposable-disk
fixture uses preapproved account templates without opening a domain or VM.


Primary areas: `Source`, `ArtifactPreparation`, credential resolver, target source
catalogs, native preparation/cache/agent workers and source/store codecs.

1. Implement digest-pinned registry `.smolmachine` preparation and typed
   `create_prepared` through audited SDK download/materialization APIs. Verify
   platform manifest, file content, architecture and local cache identity separately.
   Preserve the shared preparation/create deadline and private bounded staging.
2. Integrate per-operation credential references and protected IPC without tokens
   in durable state, public errors, argv or inherited environment. Preserve HTTP
   restrictions on explicit tokens, private/loopback targets and OCI pull fields.
3. Implement non-seeded OCI creation first unless P0 proves an explicitly approved
   seed path. Guest egress approval and host registry traffic remain distinct.
   Any auxiliary builder must be enrolled, supervised and budgeted before dispatch.
4. Implement existing-machine image listing and managed OCI image pull with exact
   approval/observed identity, launch slot and durable evidence. Reject imported
   pack/checkpoint pulls instead of reporting synthetic `packed` metadata as a pull.
5. Cover cold/warm cache, digest/architecture mismatch, credential rotation and
   redaction, bounded failed preparation and normal restart. Use approved local
   registry fixtures and deterministic errors; do not run destructive cache/CLI
   races or interrupt live persistence.

Exit gate: source/preparation/image workflows match HTTP's identities, typed
results, resource policy and current source restrictions. No hidden unowned VM.

## P5 Buffered stdin, background execution and console logs

Primary areas: `Command`, engine command/session workers, request/result adapters,
execution/store launch evidence and `LogOptions`/`LogResult`.

1. Add buffered foreground UTF-8 stdin up to the existing 64-KiB limit, with exact
   public argv/env/workdir/user/output/deadline validation. Protect against SDK
   buffered reply growth before exposing this path; use a bounded owned worker.
   Keep streaming stdin and streaming background unsupported as in HTTP.
   Foreground nil-stdin streaming must preserve full public argv/environment
   bounds and pre-Exit output delivery through the owned worker. Bind activation
   to `streaming_exec: 1` and reader-first `native_streaming_commands: 1`
   admission; older approved descriptors retain their existing limits.
2. Add retained-image background launch with nil command timeout/stdin and bounded
   launch observation. Preserve typed launched/PID evidence, not foreground Exit;
   cancellation never becomes guest termination or lifecycle authority.
3. Add bounded console log tail/follow/callback behavior using authenticated domain
   paths and existing result types. Logs cannot boot a machine, attest workload
   success or prove absence. Keep missing/unavailable/limit outcomes truthful.
4. Run shared command/log contracts for exact stdin, binary output, user behavior,
   launch evidence, deadline/cancel/no-replay and normal lifecycle. Model lost
   acknowledgment instead of killing an owner; verify sibling usability.

Exit gate: the same valid public command/log specifications have equivalent
results and durable accounting; unsupported combinations still reject early.

## P6 Interactive managed terminals

Primary areas: `Terminal.Server`/connection abstraction, `Terminal.Handle`,
native session worker, Port session controls, Runtime terminal observation/store.

1. Extract an internal terminal connection interface preserving HTTP Mint/TLS/
   WebSocket behavior. Add a native adapter; keep public Spec/Handle/Result and
   caller/observer binding unchanged. Do not make Client.open_terminal native.
   The controller consumes semantic terminal events; framing and resize encoding
   belong to the adapter. Return native byte/event credit on consumer removal,
   rather than queue admission. A credit failure closes observation conservatively
   while preserving validated output that the caller has already consumed.
2. Implement native session open/input/resize/close/output/Exit with exact epoch/
   operation identity using the SDK channel APIs. No host tty/raw mode, signal
   handler installation, stdin capture or bridge stdout contamination.
3. Bound total/per-call input, SDK pending queues, frame/chunk counts, unread output,
   work slots and closed-buffer retention. Enforce finite session/idle/attach/close
   budgets through the owned session worker. Input send is not guest consumption;
   EOF alone is not worker quiescence or guest Exit.
4. Integrate the existing durable machine command slot and confirmed/unknown
   evidence. Preserve retained-image restriction and no reconnect/reattach/input
   replay. A surviving store does not restore a live terminal connection.
5. Parameterize shared terminal contracts for single consumer, resizing, credit,
   byte fidelity, explicit normal close, observed Exit and unavailable sessions.
   Run ordinary PTY readiness/interaction/exit checks on qualified native platforms;
   model owner/store loss without live interruption.

Exit gate: existing managed terminal calls work with either backend under the
same public budgets, ownership and recovery rules. HTTP terminal behavior passes.

## P7 Local volumes, mounts and stopped disk expansion

Primary areas: volume policy/store attachments, native host-filesystem control,
SDK mount/storage APIs, disk-expansion coordinator and material transition proofs.

Implementation note: the shared engine has read-only root qualification and fresh
0700 backing staging with protected intent/completion records and bounded,
nonmutating proof observation through reserved control admission. These are
internal foundations. Native host provision additionally binds inherited
unprivileged UID/GID to a protected completion without widening backing mode.
Public readiness still needs guest/replacement-write and permitted mode/ownership
evolution qualification. Deletion preflight now excludes all retained SDK mounts
and holds root/resource/volume-gate authority in an opaque permit. Native removal
now consumes it with protected intent/completion and descriptor-relative iterative
traversal. Explicit caller-fenced resolution continues only protected entered
deletion or completed provisioning, with native gate/work/attachment checks.
Fresh schema-2 staging records synchronized temporary backing identity before
no-replacement public rename, then records distinct final staging; schema-1
reading remains compatible. Explicit fenced abort now cleans only protected
prepared/staged backing, with distinct abort proof and no ready promotion.
Unproved temporary cleanup, long/large-tree acceptance and bridge/durable/mount
integration remain pending; no volume capability or P7 exit gate activates yet.
Typed protocol-2 actions, result authority and helper adapter/catalog routing
now exist behind that disabled gate. Exact volume limits, Linux-only declaration
and job/buffered/compact feature dependencies now agree across Rust/Elixir and
executing engine constants. Elixir now validates exact requests/results, correlates action/intent/domain proof,
checks operator-root result authority and routes read-only inspection during
reconciliation/quarantine. Durable VolumeAuthority and selective v20 now retain native binding and exact
provision/delete/abort proof, with immutable linkage and proof-only completion.
Memory and the PostgreSQL example check matching enrollment at acceptance;
HTTP v15 bytes remain unchanged. Scoped backend volume construction/reply decoding and read-only startup volume
classification now preserve saved identity, immutable proofs and reservations.
Future enrollment requires native volume reader and callback support; this marker
is not advertised yet. Managed provisioning/deletion now pins the owner before durable intent, serializes
against native recovery, retains worker lease/domain binding and uses typed proof
completion with one absolute budget. Explicit fenced cleanup selects protected
staging only after confirmed pre-dispatch ownership rejection, never after
uncertainty. Deduplication stays read-only without requiring a live helper.
The shared engine now qualifies proof-bound mount sets into opaque retained root/
backing/domain/gate handles and rechecks them before projecting SDK mount tuples.
Any protected cleanup journal blocks projection. Durable attachments now preserve volume key/binding/proof/target/read-only mode
in immutable machine records with selective v21 and atomic enrolled-store checks.
Creation wire/assignment now carries exact saved mounts for local/OCI/registry
sources; retained commands inherit that authority in selective v21. Protocol and
operator-catalog gates reject mismatched feature/domain/policy. Helper dispatch
now forwards the exact approved policy and full proof into engine qualification
and material publication; current public package capability admission is disabled. The shared engine now authenticates the full mount proof set in its private
material journal and binds its digest plus exact SDK mount tuples into creation
authority. Local mounted creation consumes the qualified handle and atomically
promotes its retained lease to the whole-job budget without releasing gates or
descriptors; failures after reservation remain uncertain. Legacy unmounted
journals omit the new field. Prepared registry and direct OCI creation now also retain/promote that handle
and publish authenticated mount material without reacquiring work capacity.
Cancellation and foreign-handle contracts reject before reservation/SDK mutation.
SDK mount observations now project actual source/target/read-only/staged values
through protocol 2, including offline mounted machines. Strict wire contracts
and managed reply correlation reject missing, changed or unexpected mounts; old
unmounted observations omit the field exactly. Local/prepared-pack startup now
requires a freshly qualified handle matched to the full saved material, retains
its gates/descriptors through SDK entry and observation, and atomically reserves
one launch child under the existing whole-work budget. Ordinary start without
a qualified handle rejects mounted records. Port now routes mounted local/OCI/
prepared-registry creation to these paths. Source preparation finishes before
mount qualification to avoid stacking work leases, with one original deadline.
Pack startup selects journal-bound mounts only against the current operator
policy. OCI startup now qualifies full saved mount proof and atomically promotes
the existing lease to its launch/bootstrap job. Mounted bootstrap spools and
worker dispatch wait until SDK agent readiness and parent backing/root FD closure;
volume gates, domain and proof follow worker collection. The declared descriptor
limit is unchanged. Buffered, owned streaming and background commands now
qualify saved/current mounts before machine gating, recheck running authority,
and atomically promote the retained lease to worker/output admission. Parent
backing descriptors close before worker preparation; full proof and volume gates
follow collection. Policy-aware Port dispatch retains credited output, and the
unqualified command paths reject mounted records. Managed terminals now use
the same current-backing qualification and retained worker authority, including
exact terminal input staging and unchanged control/output credit. Port forwards
the current operator policy. Live phase/resource qualification, reader activation
and ordinary acceptance remain pending.

1. Implement Linux local volume provision/delete using the canonical approved SDK
   root and generated durable IDs. Add authenticated native operation evidence;
   do not adopt directories, follow substituted paths or remove unrelated content.
   Validate actual dedicated-account modes/UID replacement writes rather than
   blindly copying upstream's permissive directory creation.
2. Carry approved volume attachments into SDK machine/workload mount structures.
   Preserve one exclusive attachment, allowed guest targets, read-only mode,
   independent disk reservations, drain behavior and attachment release only after
   verified machine deletion. Do not add arbitrary host mounts to the managed API.
3. Implement stopped/created growth with public SDK storage APIs selected by P0;
   never assume running resize satisfies the contract. Grow only to approved
   absolute 1–64-GiB targets. Reserve the full increase before dispatch, verify
   geometry and return authorized material proofs without changing creation intent.
4. Add durable uncertainty/duplicate/history/codec contracts for both operations.
   Exercise ordinary Linux provision-write-replace-read-delete and stop-grow-start
   witnesses. Record native macOS volume rejection; macOS growth stays unqualified
   unless separately tested. Resource declarations remain admission, not quotas.

Exit gate: Linux storage features match public HTTP behavior, maintain ownership
after legitimate geometry changes and retain capacity on uncertain outcomes.

## P8 Checkpoint restore/capture, exports and managed branches

Primary areas: checkpoint/capture/export/branch coordinators and artifact IO,
native public SDK saved-state/packer/fork APIs, epoch actors and store proofs.

Imported-container note: the coordinator now retains the receipt-bound original
`.smolmachine` from either engine creation cache, verifies whole-file/CRC/per-layer
hashes and derives ordered layers plus bounded logical expansion. Frozen original
versions follow the owned worker through collection; the worker independently
rehashes before guest I/O and streams verified layers as bounded guest parts,
extracts into fixed helper paths and removes raw parts before the next layer.
Protected resource plans fund all expanded layers, the largest temporary tar and
filesystem overhead. This does not trust/repair SDK caches or copy host tars.
Ordinary SDK storage/mount/tar semantics and local/prepared-registry export/import
qualification remain required. Raw SDK host-directory/archive forms are not
additions to the managed `Source.local/1` API.

Ordinary SDK qualification note: the opt-in Port test fixture selects an explicit
storage/launch/conversion/packing phase, approved package/config and original
stopped-source receipt in the actual default SDK namespace. It performs no
database-only fixture adoption or in-process environment redirection. Initial
macOS storage/COW qualification passed; helper launch exposed immutable template
permission inheritance during expansion and unmodeled format/readiness files.
The initializer now formats at the one-GiB approved baseline, makes only owned
copies writable and grows via public SDK APIs. Exact SDK format markers gate
launch configuration; legacy unformatted records remain cleanup-only. Bounded
post-collection custody includes failed shorter disks without granting launch or
export success. Ordinary requalification of these changes remains required.

Entered-capture resolution note: the shared engine now records a distinct
`CaptureResolutionTransition` only for an exact entered intent and verified
quiescent stopped source. The ordered journal retires the ID without publishing
artifact success, including when the checkpoint head is unchanged. Independent
bounded material-control admission permits this while capture reservations stay
retained. Public integration
and authenticated staging/native allowance release remain required before this
boundary can resolve public unknown captures. Non-VM models are not ordinary
source/package/platform qualification. Protocol-2 resolution and exact recorded
lookup are now routed through the helper with positive quiescence, 30-second
budgets, distinct zero-output replies and reserved control admission. Strict
Rust/Elixir validators and an in-process native peer cover the wire/control
boundary. Typed source-only histories, selective codec v25, the separate
`native_capture_resolutions: 1` reader and guarded Memory/PostgreSQL transactions
now preserve stopped source authority with unknown artifact results. Whole-chain
validators enforce known absent heads and exact ordered lineage. Public explicit
resolution now routes native-only `qualify_capture` after authority/quiescence and
version claim; completed/recorded lookup precedes any entered-source qualification.
Read-only recovery imports no durable proof and never dispatches resolution.
Entered running-source resolution now requires the original enrolled engine start,
current SDK PID and OS PID/birth under the collected-worker gate, with stopped
resolution preserving process-absence checks. Native/durable models keep the
source running without artifact adoption. Authenticated staging/allowance release
and ordinary live qualification remain required; checkpoint capabilities stay
disabled.

Capture staging note: schema-1 protected stage registration now precedes source
intent/SDK dispatch and binds original authority, directory identity and worker
metadata digest. Unknown collected stages retain real native leases in a registry;
replacement restores declared admission from verified private records. Unindexed
or substituted stages cannot be adopted, cleaned or used to release capacity.
Explicit retained-stage cleanup, native allowance release and public qualification
remain required. These filesystem/lease models run no live fault campaign.

Retained cleanup note: the shared engine now explicitly removes only a protected
collected stage with correlated completed/resolved source evidence. Durable
Cleaning/Cleaned phases bracket descriptor-relative removal and actual allowance
release; known partial/removed-root attempts resume without capture replay.
Typed protocol-two `cleanup_capture_staging` now routes through the Port adapter,
with positive quiescence, checkpoint feature approval, a 30-second absolute
budget and an exact zero-output `capture_staging_cleaned` receipt. Rust/Elixir
validators bind original receipt/ID/request and keep cleanup distinct from
material resolution and successful artifacts. Reserved control scheduling and
quarantined pinned calls permit cleanup without reactivating work. Public/store
release integration and ordinary qualification remain required. Before
stopped-source SDK deletion, protected stage records now retain
the exact current deletion receipt after complete/resolved source verification.
Later cleanup requires that enrollment plus verified source absence; a missing
row/directory alone grants no cleanup authority. Deletion checks the caller's
budget before enrollment and SDK entry. Non-VM models cover replacement,
recreated/uncollected sources, cancellation and stable cleanup receipts. Ordinary
live deleted-source qualification remains required.

Prepared-stage abort note: `abort_capture_staging` now requires exact registered
pre-entry authority, positive quiescence and the source gate. It clears only its
own unentered source intent and preserves subsequent source operations/material
history. Durable Aborting/Aborted phases use a distinct proof digest, descriptor
cleanup and synchronized allowance release. Recorded partial removal resumes;
unproved absence and entered/collected capture stages cannot supply abort success.
Ordinary pre-entry retirement keeps its actual lease recoverable on failure.
Protocol-two reserved control routing returns an exact zero-output
`capture_staging_aborted` reply without reactivating work. Public/store integration
and ordinary source/package/platform qualification remain required.

Completed-stage closeout note: registered completed capture guards now retain
their actual lease, verify exact source completion, and use bounded descriptor
cleanup with a durable Cleaned receipt rather than removing the ledger record.
The source gate survives closeout. Missing completion evidence or substituted
roots preserve recoverable reservations and quarantine work. Explicit qualified
cleanup can record collection for an earlier Prepared/Entered stage only after
correlated source completion/resolution, retained capacity and original root
identity checks. Non-VM models cover normal replacement, source preservation,
false completion flags and substituted-root recovery. Public/store receipt
consumption and ordinary exact-package qualification remain required.

Durable cleanup note: native capture acceptance now freezes the source receipt;
Memory/PostgreSQL guarded release takes exact cleanup evidence and atomically
persists it with reservation release. First native release without evidence is
rejected, while HTTP uses the unchanged request form. Already consumed identical
evidence is idempotent; crossed/stale or replacement evidence cannot mutate
accounting. Source enrollment and cleanup fields selectively require codec v26 and
`native_capture_cleanup: 1`, with older nil-default stripping and legacy rejection.
Reader/writer enrollment is required before a future checkpoint helper. Public
release now pins/quiesces its owner under native authority serialization, obtains
scoped `cleanup_capture` evidence, rechecks host output absence and commits it with
fresh store authority. An exact pre-dispatch state reply can select prepared abort
only for an already resolved transition-free capture; uncertain results cannot
select another operation. Live-source pre-entry abort qualification remains
required independently of stage cleanup, along with ordinary qualification.

Pre-entry source authority note: native registration now preserves original
source intent/PID/birth before SDK entry. `qualify_aborted_capture_source` requires
exact Aborted evidence, positive quiescence, domain/source gate and unchanged
source material. Running sources require actual engine/cache/start ownership;
stopped sources require verified original-process absence. Its distinct proof
neither advances material nor supplies capture/artifact success. Legacy stage
records without this evidence cannot borrow it from inventory. Port/public/store
routing and ordinary qualification remain required.

Implementation note: checkpoint approval/header eligibility now has a shared-engine
type with exact SDK/platform/allocation and idle bare dependency checks. Its
64-GiB artifact allowance is separate from ordinary pack/command/file limits.
Both SDK header layouts are represented; CPU compatibility stays with the public
SDK validator. The convenience restore API owns a separate reservation and may
clean storage on failure, so fresh SmolBox authority will use public checkpoint
materialization/installation under its own reservation. Bounded byte/assets
preparation remains distinct from read-only inspection. Engine inspection now
checks the operator SHA-256, bounded sidecar layout and public descriptor-based
SDK checksum/CPU compatibility. Streaming validation requires the classic asset
inventory and digests, profile-derived expansion bounds and the SDK format’s
64-file disk-chain limit with correct top-level/backing targets. History validation bounds indexes/objects and authenticates object
content. Request-private preparation now copies authenticated bytes into the
owner domain, holds separate finite staging/parser allowances and validates
SDK-written history indexes through public readers/StoredFile serialization.
Index policy binds exact files, referenced object lengths and hashes, whole-file
digests and head/ancestor lineage/data summaries. Retained ancestors preserve
their captured allocations, including earlier disk sizes.
Read-only cancellation retains executing admission without quarantining siblings.
Owned worker materialization now uses public SDK classic extraction or uncached
store materialization, with four chunk threads, finite decoded staging and exact
collected evidence. MaterializedCheckpoint retains source/domain/admission and
rechecks the private output inventory, versions and declared digests. An ordinary
non-VM helper fixture exercises both layouts; this is not restored-VM qualification.
Fresh installation now reserves the SDK name, creates a ticketed private VM
directory and uses the public SDK installer in an owned no-signal worker. Exact
collected installation evidence and parent rechecks precede neutral bare record
and creation/material proof publication. Partial storage is retained on error;
name/gate/source/native leases survive unresolved collection. A non-VM fixture
installs sparse disks and commits an owned stopped SDK row. First-start now has a receipt/record-bound private journal with pending, entered
and consumed phases. Dispatch intent is persisted before SDK entry; only successful
SDK start with matched live PID/birth and consumed inputs completes it. Observers
keep entered state unknown and cannot replay or cold-boot missing pending inputs.
A normally stoppable VMM still requires this engine’s enrolled handle/PID proof.
Five deterministic models and a non-VM installed-row fixture exercise these
boundaries. The helper now accepts a separate optional checkpoint approval
catalog (at most 32 unique IDs), binding immutable source identity, operator-only
path, current SDK/native platform, captured resources and the independent 64-GiB
input ceiling. Elixir publishes this catalog only for an explicitly advertised
checkpoint feature; omission preserves old configuration bytes. Catalog parsing
does not open inputs, prepare material or grant existing-machine authority.
Path-free qualification, creation and absence operations now select an exact
catalog identity/resource pair before native admission. Shared-engine approved
creation retains one absolute budget across preparation, materialization and
installation, with identity/template checks before staging. Absence is admitted
read-only and never opens the checkpoint, repairs a row or recovers a receipt.
Rust session and Elixir request/channel contracts bind replies to request kind
and exact receipt identity. Managed qualification/creation/absence routing and
selective v22 restore-source assignments now preserve exact capture profiles,
immutable creation resources and retained-command authority. Runtime requires
the separate native_checkpoint_sources reader before enrolling a future
checkpoint-capable package. Memory and the PostgreSQL example support the
reader/atomic reservation foundation; HTTP and earlier native encodings remain
unchanged. Expanded capture/export/branch histories, explicit resolution,
large-history scalability and ordinary restored-VM/
platform/consumer qualification remain pending; no checkpoint capability
is activated by inspection.

1. Implement approved checkpoint restore into a fresh authenticated creation
   intent. Preserve CPU/runtime/platform/topology compatibility and forbidden
   dependency checks. Starting after a later stop does not reapply captured RAM.
2. Add checkpointable startup, preflight and bounded capture using SDK APIs.
   Preserve idle offline bare-source limits, controller-private streamed artifacts,
   extra resource floors, immutable source authority and source resume on success.
   Startup foundation now binds forkable in fresh local/registry material before
   receipt publication; ordinary SDK start honors it without an untracked update.
   Core/Port start and read-only preflight require authenticated source material
   and reject promotion of an ordinary record. Preflight verifies enrolled live
   PID/birth and does not assert guest idleness. Capture updates checkpoint_head
   in the SDK, which may warn rather than fail on persistence error: implement a
   distinct correlated material transition before treating its result as complete.
   Fresh creation now retains explicit true opt-in in qualification and creation
   requests, selects the checkpointable local/registry constructors, and uses
   selective codec v23. Attached commands retain the original marker. Runtime
   requires native_checkpointable: 1; older native readers reject the field and
   ordinary/HTTP requests keep their encodings. Source SDK dispatch, capture
   budgets/streaming/collection and saved histories remain pending. A distinct capture
   material journal foundation now binds request bounds/idle assertion, source
   PID/birth, previous receipt/head and exact artifact digest/size/lineage. Prepared
   and entered intents fence other mutations. Completion permits only a resumed
   source and checkpoint-head material change; SDK persistence warnings cannot
   complete it from artifact existence. Capture/growth history shares ordered
   revisions without reinterpreting proof types. Full journal file versions fence
   in-place changes. These interfaces are exercised by non-VM models and are not
   yet invoked by a production capture coordinator. Ordinary running-source
   qualification also remains pending.
3. Implement stopped-source export with exact container/bare preservation rules
   and approved registry destination/token/receipt. Select the bounded approved
   host-conversion or fully enrolled auxiliary-VM approach established in P0;
   never reuse the private fixture exporter as qualified product behavior.
   Gated typed Port preflight/publication/lookup/cleanup now connect the bare
   shared-engine path. Setup snapshots exact operator destination/TLS approvals;
   reader admission uses cached hashes/caps only. Rust/Elixir correlate canonical
   publication and separate cleanup evidence to original source/request and
   package architecture, with reserved control lookup/cleanup. Managed controller
   routing now snapshots active export authority and uses the same pinned helper
   for preflight and publication. Controller qualification selects only cached
   destination hash/caps, accounts source logical bytes within staging, and
   freezes the derived request before dispatch. Exact acknowledgement lookup
   precedes existing independent registry verification. Native history freezes the enrolled source
   at acceptance and the exact bounded request before dispatch. Selective v28
   retains correlated native acknowledgement and distinct cleanup proof; guarded
   completion releases allowance only with exact cleanup, preserving HTTP v11.
   Future package enrollment requires native_export_histories: 1. Controller
   pinning/quiescence and lookup/cleanup orchestration now consume correlated
   proof with one control deadline and reject changed intent before release.
   Explicit live-source no-stage cleanup now authenticates marker/current
   material under the source gate and writes schema-4 zero-byte retirement.
   Its separate proof domain gives no publication or VM-absence authority and
   fences operation reuse. Existing registered stage cleanup is independent of
   VM-row lifetime; a private removed-source model validates that boundary.
   Pre-disposal intent authority when an unstaged source is already deleted,
   container flattening and ordinary
   qualification remain pending. The retained conversion token now connects one
   owned SDK launch through the original budget and per-entry work retention.
   Protected schema 8 records the opaque entered boot intent and exact returned
   pre-exec child identity. Return grants no collection, replay or cleanup proof;
   normal reopening retains capacity/quarantine without adoption. Original
   enrollment is now retained separately from record publication. Bounded owned
   collection controls select the original manager/child, including quiesced
   retired callers; schema-8 collecting/collected phases record opaque collection
   without guest fsync, filesystem cleanup or publication authority. Ordinary
   non-VM child and private control/reopen models pass. Schema-9 runtime custody
   now binds exact bounded SDK files/socket and the original rootfs helper marker
   after opaque collection. Explicit removal records intent before unlinking,
   rejects changed/unknown inventory, resumes only captured remaining files and
   verifies/syncs absence before release. Private filesystem models pass; actual
   SDK file inventory/rootfs behavior and ordinary SDK startup/shutdown
   qualification must follow before public conversion admission. Frozen worker
   input now derives from the qualified source and reserved conversion grant.
   Fixed private-source mount/cache binds, a bounded typed exact cached query and
   validated topmost-first flatten plan connect to streamed layer I/O. SDK-encoded
   loopback checks pass without a guest. The original retained entry now dispatches
   one isolated conversion worker through its existing job reservation. Distinct
   private layer/plan spools stay retained through actual child collection;
   parent verification binds both sizes/hashes to frozen input and rechecks the
   source/plan. A live or retained-output worker lease fences helper collection
   and cleanup. Bounded positional reads supply no tar/publication authority.
   Protected schema 10 now consumes that exact original-entry output through a
   no-replacement descriptor-relative move, avoiding a second tar allocation.
   Entered/ready layer records bind input/plan hashes, file identity, bytes/hash
   and original budgets. Rehash plus read-only mode precede ready registration;
   the original plan remains retained for future packing. Collection/runtime
   retirement preserves the layer schema. Deterministic private models cover
   pending moves and normal cleanup/reopen without writer adoption. Packing
   requires original opaque collection before explicit helper retirement. Fresh
   schema 11 now records retired-helper readiness, packing intent, writer entry
   and original empty output inode before body writes. The bounded shared packer
   emits one SDK digest-named layer plus approved assets, SDK-seeded inherited
   metadata and a verified sidecar/footer. Generic packed-export forwarding,
   single-attempt publication and cleanup retain the original container entry,
   including across normal Engine value drop. Private format/ledger/registry-peer
   and retention models pass; they do not qualify SDK helper production or guest
   import. A transport-independent engine coordinator now selects actual source
   mode and sequences source qualification, explicit funding, owned SDK storage/
   launch/worker/registration/collection, packing and existing publication. The
   Port adapter delegates this path. New cached grants produce frozen upper
   bounds without guessing mode; old catalogs retain exact request construction.
   Bare geometry and actual container layer bytes determine effective pack caps.
   Shared output budgets bound aggregate helper/tar/artifact bytes without a fixed
   split; legacy fixed records keep their bytes. Quiesced cleanup collects only
   an original retired manager, permits provably unentered storage retirement and
   skips SDK replay after collection/runtime custody. Active callers/workers still
   reject. A non-VM staged-artifact witness now packs more than 16 MiB and
   exercises one-MiB upload credit, 256-KiB reads and incomplete acknowledgement
   bodies against the production uploader. Resume, explicit cancellation and
   deadline retirement preserve original source/staging allowances and both
   control observers; blob completion cannot supply publication proof. Native
   registry clients explicitly disable automatic library retries. This does not
   traverse guest/worker conversion or qualify aggregate OS memory. Whole-pipeline
   output-credit validation, local/imported source semantics
   and ordinary public/platform qualification remain required. Private record/control models
   are not positive SDK startup qualification; deterministic controller models do not prove
   the helper can produce every required cleanup witness.
   No public export capability is enabled by this wire foundation.
4. Add branch source/absence/create/inspection/hold/release with authenticated
   source and independent child proof, atomic dual reservation, ordered gates and
   owner-epoch enrollment for forked VMMs. Keep one-leaf/offline/bare restrictions,
   extra backing allowance and parent dependency checks through child retirement.
   Initial read-only admission now retains an originally enrolled unbranched
   source and fresh child under lexical gate order, with post-lock source/root/
   PID/absence rechecks. Exact policy/profile resource plans match public store
   admission through shared Rust/Elixir cases. The digest binds both identities,
   operation/hold, source PID/birth, owner epoch and SDK/shared-RAM strategy.
   Work metadata/FD admission leaves control separate. The original opaque guard
   can now persist a protected initial source/child declaration in the existing
   material journal. Its exact resource plan, receipt, PID/birth, owner epoch and
   request digest survive normal reopen and fence other source mutations. An
   original retained guard can explicitly abort unchanged pre-SDK intent using a
   separate cleanup budget, with unchanged source material and verified child
   absence. Abort now persists a distinct retirement receipt before acknowledgement,
   keeping source material unchanged while preventing operation-ID reuse. Explicit
   quiesced retirement can recover prepared-only intent after a normal stopped
   replacement, using positive source authority, ordered gates and child absence.
   Recorded-result lookup precedes current-state checks and never replays mutation;
   None grants no absence or release authority. Retirements bind actual historical
   heads and share the finite operation-history budget. Dropping a guard never
   retires intent automatically. A checked engine request now correlates the full
   host creation request and explicit quiescence with a required bounded retirement
   acknowledgement. Protected history selects the private native admission digest
   only after exact source/child/approval matching; the caller cannot supply a
   replacement native PID/epoch/digest. Initial-release fields correlate unused
   host intent and attest no SDK activation. The existing native proof still
   attests only its unentered declaration. Missing/entered declarations cannot
   become absence even with empty SDK inventory. Known retirement lookup remains
   historical and does not re-enroll ownership. The finite control allowance is
   released between lookup and retirement, and child-absence SQLite reads now use
   the same caller deadline/cancellation. Protocol two now carries
   retire_prepared_branch with a required bounded typed acknowledgement. Rust and
   Elixir independently validate the native intent, both proof hashes and exact
   host source/child/approval correlation. Immutable branch approval and Inspect
   capability precede control-lane dispatch; zero output and source-domain binding
   are mandatory. The existing finite branch terminal storage preserves both
   observer frame reservations. Conversion/correlation failure after native return
   remains uncertain. The store now retains a distinct typed prepared-retirement
   entry on source and child under selective v36. A child-version-bound proof plus
   a fresh unchanged source observation atomically closes only the never-created
   child and releases its ordinary/pre-entry reservations. The tagged source entry
   remains outside material transitions and permanently excludes ID reuse by
   branching or capture. Memory/PostgreSQL share this transaction and rollback
   contract. Exact earlier envelopes and fresh-BEAM reading remain supported.
   Public `Branches.resolve` now consumes this proof for explicit deleted
   resolution through native-only retire_prepared_branch/3. It keeps the original
   helper/controller fence through both bounded backend stages and final paired
   store commit. The stages share one deadline and aggregate JSON payload budgets;
   the Port independently bounds each framed message. Only a current child version
   and fresh unchanged source observation can complete. Post-proof/host/store
   failure stays uncertain, and a saved acknowledgement returns without helper IO.
   Missing/entered proof retains reservations. This adds native recovery plumbing
   for the same SmolBox feature scope; it enables no public native branch admission
   or SDK qualification. Prepared retirement grants no persistent backing reservation,
   SDK fork dispatch or child proof. Bounded private fork-preparation workers
   now call the clean held-fork API only after an exact protected entered grant.
   The original admission promotes atomically to two child slots, 24 work descriptors,
   80 KiB of IPC staging and the existing saved-state metadata allowance, without
   taking a second work slot or either reserved observer. Metadata binds the
   original owner, nonce, source/root/database identities and absolute deadline.
   Worker results distinguish a continuing source and a Created no-PID held child;
   source lineage and copied child labels cannot supply ownership. Private IPC
   requires a distinct correlated terminal proof, not a generic file acknowledgement.
   The producer additionally charges computed child-plus-minimum-extra disk
   backing against the existing finite saved-state material allowance. An original
   engine registry now retains source/child gates, SDK runtime, spools and admission
   independently of caller retirement. Automatic creation now freezes the full
   bounded host request before SDK entry, including the initial-release choice.
   A fresh explicit resolution call can exclusively borrow only that exact
   original entered registry entry after its creation borrower/worker retire.
   Source/domain/runtime identity, live helper epoch, quiescence and a captured
   thirty-second deadline/cancellation remain mandatory. Phase lookup supplies no
   disposal proof or authority to replay creation. Old unbound/prepared-only work and
   completed children use separate APIs. Dropping the borrow leaves every
   original lease/gate/context intact. This original-context selection foundation
   now supports separate explicit disposal of a fully published, never-booted
   child. Bounded control admission, exact original directory/metadata identities,
   protected source publication and unchanged live source authority precede a
   synchronized disposal-entered grant and one original-runtime SDK deletion.
   Missing or exact prepared-only boot plans qualify only with no manager,
   enrollment, child process, dependent child or real layers-cache directory.
   Row, creation-reservation and directory absence plus unchanged source/snapshot
   are required before a durable typed acknowledgement. SDK success and later
   observed absence have distinct completion provenance. An entered unknown
   deletion cannot be retried; explicit resolution only observes its exact grant.
   Historical completion never touches recreated material or asserts current
   namespace absence. Missing evidence cannot be rebuilt from phase or labels.
   Disposal itself retains every original gate, transient lease and backing
   charge. A separate finish_unbooted_disposal step now verifies the exact durable
   proof and unique original job before transferring the same runtime/domain and
   full backing charge into bounded disposed bookkeeping. Only original temporary
   spools, pinned roots, work allowances and machine gates retire. No manager,
   boot readiness, BranchCompletion or released backing is fabricated. Historical
   lookup requires the original archive and protected ledger; recreated material
   is untouched. Proof recovery re-synchronizes the exact ledger file and directory
   before acknowledging or retiring work. Failed unique conversion restores the
   whole original registry entry. Live helper identity, quiescence, one captured
   budget and bounded control admission still apply. Native disposed backing
   retirement now uses a distinct full-disposal request and the exact original
   archive/ledger, without manufacturing BranchCompletion or enrollment. It binds
   the caller's source tombstone head, exact unbooted child root, distinct operation,
   quiescence and host removal confirmation. Original actor/source collection and
   bounded SDK row/reservation/directory absence precede a protected accounting
   receipt and release of only that native charge. The owned worker retains
   ordered gates/control admission through actual return, including observation
   cancellation. Saved acknowledgements neither requalify recreated namespaces
   nor release a charge twice; missing archive or evidence cannot reconstruct
   authority. Source tombstone heads remain caller correlation, not an invented
   native history proof. Backing metadata/history stay retained. Other partial/
   boot-entered states, Backend/Runtime/store integration and ordinary SDK
   qualification remain required. Protocol-two dispose_unbooted_branch and
   resolve_unbooted_branch_disposal now bind the full creation and disposal
   request. Both require explicit quiescence; resolution never dispatches SDK
   deletion. Original archived completion returns without namespace adoption;
   otherwise the same retained original job supplies disposal/observation and
   terminal handoff. Distinct release_unbooted_branch_backing carries the full
   disposal and caller tombstones to the checked accounting route. Requests and
   required nonnullable results have independent Rust/Elixir validators, immutable
   catalog/domain/platform binding, thirty-second budgets and zero event output.
   Disposal input caps at 20 KiB with 16-KiB creation, its proof at 32 KiB; backing
   preserves existing 80-KiB request/68-KiB proof bounds. Branch terminal
   reservations apply even with a stalled writer. Proven disposed-job handoff
   can retire transient work during quarantine without reopening admission or
   releasing backing; ordinary ready-manager handoff still rejects quarantine.
   Thirty-two inert disposal/handoff/backing models plus synthetic cross-reader,
   helper policy/output and Elixir channel contracts exercise these boundaries
   without SDK dispatch or a live crash campaign. No public admission or codec
   marker is enabled by this transport step. NativeUnbootedBranchDisposal now
   saves its exact version/request before dispatch through paired branch_advance
   acceptance. Claims preserve that request; only a current child-version result,
   matching typed proof and fresh source observation can complete through
   branch_resolve. The real source publication advances its actual material head.
   A deleted never-booted child retains proof without created/observed Machine or
   BranchCompletion. Ordinary reservation alone retires; the source dependency
   and extra backing stay charged. Dedicated disposal_pending/disposed states
   require the new authority and prevent stripped schema downgrades. Selective
   v37, exact earlier-envelope omission and fresh-BEAM readers preserve this state
   in Memory/PostgreSQL, including paired request/result/projection rollback.
   Native dependency retirement and host backing closure for this origin remain
   required; no store capability marker is advertised.
   Before accepting a new entered-disposal intent, obtain positive original-job
   selection evidence. Read-only inspect_unbooted_branch_disposal now checks the
   exact original published, never-booted job, no active worker/disposal grant,
   live source and exact material. Its typed candidate binds the full frozen
   creation, actual source publication and original preparation digest. Engine,
   Port and Elixir readers preserve original helper epoch/platform, branch
   approval, finite observation budget and zero-output correlation. It neither
   dispatches SDK work nor releases any charge. Prepared-retirement errors are
   never selection evidence; previously accepted disposal uses its saved request
   and observation path. The source-scoped backend now exposes native-only
   inspect_unbooted_branch_disposal/3, dispose_unbooted_branch/3 and
   resolve_unbooted_branch_disposal/3; HTTP rejects all three. Public deleted
   resolution preserves prepared retirement first, requires positive candidate
   evidence before accepting entered disposal, and retains one original helper/
   controller fence through the guarded final paired write. Saved intent skips
   selection and observes its original ledger before offering the same request
   to independently protected one-shot dispatch. Cached completion needs no IO.
   A single deadline covers stages and commit admission; offered transfer bounds
   are charged across stages even on failed replies. Missing/wrong/late evidence,
   stale claims or either store failure preserve retained state and charges.
   Fresh source observation evolves only the actual publication and uses complete
   material history for disk geometry. Host backing closure, remaining partial/
   boot-entered states and ordinary acceptance stay required.
   No public native admission or store capability marker is enabled.
   Fresh dependency-retirement evidence for this origin now has a distinct
   UnbootedBranchChildAbsence request/proof. Engine qualification requires the
   exact original disposal archive/runtime/domain/protected ledger and child
   epoch quiescence, with SDK row, creation-reservation and original-directory
   absence before and after issuance. Source collection is not required; the
   source may remain running. No manager/boot enrollment, SDK mutation, dependency
   retirement or accounting release occurs in this observation. Protocol-two
   qualify_unbooted_branch_child_absence uses exact branch approval, Inspect,
   original epoch/platform/domain, reserved control/terminal capacity, zero output,
   30 seconds and bounded 68-KiB request/proof. Rust and Elixir share synthetic
   fixtures and strict request/result correlation. Source-scoped native-only
   retire_unbooted_branch/3 now obtains this fresh proof for public retirement.
   Fingerprint/current child version/full disposal bind its canonical request.
   One pinned helper/controller fence and deadline cover observation and final
   guarded branch_retire admission. Paired success retains immutable disposal
   plus version-bound retirement, sets only the source dependency flag and leaves
   every backing charge retained. Cached retirement needs no helper IO. Missing/
   wrong/late proof, stale child versions or failed commit cannot retire a flag.
   Selective v38 preserves old disposal-only and legacy bytes, rejects downgraded
   new semantics and decodes without native assets in a fresh BEAM. Memory and
   PostgreSQL share the contract with paired rollback of records/crypto/projections.
   The completed-child backing path remains guarded against this new origin.
   Host backing closure and ordinary SDK/platform acceptance still need completion;
   no readiness or boot-completion surrogate is permitted.
   Fork preparation's synchronized entered writer precedes
   exactly one private SDK preparation dispatch; write/worker uncertainty cannot
   downgrade to prepared abort or replay. Normal collection keeps all original
   authority, rehashes original metadata/result inodes and checks bounded source/
   child rows, snapshot identity, source PID/birth/enrollment and the exact
   prepared child plus every protected earlier sibling. It mints no child receipt and publishes no source
   material. Original unentered cleanup integrates explicit quiesced retirement;
   recorded retirement can release its retained lease after lost acknowledgement
   without a second journal write. Entered teardown retains the original runtime,
   domain and allowance instead of dropping them. Five non-VM ownership/output/
   retirement models and atomic backing admission cover these boundaries; synthetic
   process facts establish no live enrollment. The exact opt-in ordinary worker
   test proves namespace rejection, normal child collection, unchanged private
   database and retained leases. None qualifies an SDK fork. Explicit native
   material publication now records an exact protected publication plan before
   child row/identity writes. It replaces copied ownership labels with independent
   child owner/incarnation and a digest bound to the original source/intent/raw
   child/generation. Atomic no-replacement marker publication and a branch-bound
   child root journal precede the source transition. Completion requires the
   original running source authority and actual child marker/journal; it never
   boots or releases the child. The source keeps its immutable creation fingerprint
   and advances a distinct ordered branch proof, even for a macOS material no-op.
   Branch/growth/capture/resolution/retirement histories reject shared operation
   IDs and preserve immutable/head linkage. Completed lookup recovers exact
   acknowledgement without another SDK call or journal write. Both gates, snapshot,
   runtime and backing remain retained after publication. Four non-VM models
   cover identity, partial publication, exact retry, historical lookup, marker
   substitution and mixed histories. Public codecs/history/dual-reservation,
   entered resolution, completed child initialization/enrollment integration and
   held release still precede public activation and ordinary live qualification.
   A native-only explicit child boot now selects the retained snapshot and source
   UID-share directory through public AgentManager APIs, using existing disk
   handles without formatting, cold fallback or SDK convenience fork/retry.
   A protected first-boot journal records entry before dispatch and the original
   opaque epoch enrollment after SDK return. The manager, gates, runtime and
   backing remain retained through cancellation or uncertainty. Bare-pack inputs
   are rehashed and pinned from the original creation cache. SDK return alone
   grants no initialized readiness; ordinary cold restart rejects until explicit
   initialization is recorded. Seven non-VM models cover snapshot/root identity,
   epoch correlation, no replay, protected journals and pinned bare inputs.
   The retained coordinator now has a distinct native-only initialize_child
   step. Its fixed bare-guest program runs through the public SDK AgentClient
   behind header-first reply limits and an absolute deadline/cancellation socket
   guard. Positional child/nonce/clock arguments cannot become caller programs.
   Protected entry binds the exact program, boot enrollment, child and challenge;
   only exact successful confirmation records IdentityReady. It never releases
   the helper, enables cold restart or retries entered work. Seven non-VM contracts
   cover identity/program binding, exact confirmation, public SDK exchange,
   oversized headers, deadline/cancellation, unchanged source/child rows and protected
   journal transitions.
   Native original-job release now distinguishes automatic inherited-helper
   acknowledgement from explicit typed held activation. Both use the public SDK
   agent protocol with empty environment, exact capability/response checks and
   no retry. Protected first-boot and material intents precede agent entry.
   A full-row CAS changes only the held flag after exact acknowledgement;
   distinct child material preserves its immutable creation fingerprint. Both
   synchronized completions are required before restart authority, and exact
   recorded lookup performs no SDK call or journal rewrite. Seven non-VM models
   cover both paths, malformed/duplicate responses, header/capability/cancel
   rejection, no replay, flag-only uncertainty, proof histories and compatibility.
   This native path uses the original admitted creation budget. Later public
   held release needs fresh store/version admission after manager handoff.
   Original-job finish_child now checks actual original boot/source authority,
   collected IPC, unique retained ownership and synchronized material/first-boot
   state before installing the same manager in the shared direct-manager cache.
   HeldReady completes held initialization without release or restart authority;
   released children keep their proved material receipt. Original boot enrollment,
   source runtime and domain follow the actual manager. Temporary roots/gates and
   work/parser/FD/launch allowances retire only after that transfer. Backing stays
   charged with separately bounded completed metadata (128 KiB per child under
   128 MiB), leaving executing parser and both observers available. Completed
   original-token lookup is read-only; teardown retains unresolved backing.
   Source observation can recognize continuing original sources only against
   protected current child heads and original live enrollment, while lifecycle
   dependency exclusion remains. Direct-manager commands use the existing owned
   worker path rather than reconstructing another SDK manager. Seven additional
   non-VM models cover accounting, held restrictions, candidacy and rejection.
   Native release_held_branch now admits later activation after manager handoff
   under a fresh absolute budget, using the original context and opaque enrollment.
   It reserves one work slot, 20 descriptors and 32 MiB temporary metadata, plus
   128 KiB persistent result metadata without charging the same disk twice.
   Ordered source/child gates, an SDK child lease and the current protected source
   head follow the one-shot shared release sequence. Both journal completions and
   tracked receipt promotion precede temporary lease retirement. Unknown entry
   retains its leases and never replays; historical result lookup never re-enrolls
   a missing handle. Seven private models cover these boundaries and accounting.
   Native branch_preflight now separates branch source admission from capture
   preflight. It checks the current protected head, bounded dependent rows and
   original live source enrollment before a bounded agent probe, then rechecks
   authority under the original absolute budget. An existing leaf is eligible
   only through its independent published origin and current protected material.
   Prepared/entered checks exempt only their exact new child; unknown siblings
   reject. Worker preflight, collection, publication, boot/initialization/release
   and handoff all retain these checks. Prepared-only retirement can preserve
   earlier leaves. Capture and ordinary source lifecycle dependency exclusion
   remain unchanged. Four private non-VM models cover a second publication,
   unchanged earlier child, pending/exempt boundaries and original-owner rejection.
   Explicit native deletion now handles completed original held children without
   permitting ordinary held stop/start. It retains the original context, ordered
   source/child gates, work and SDK lease before a protected domain record enters
   Collecting. Only original opaque epoch collection permits a stopped-row CAS
   and Deleting; positive SDK reservation/row/directory absence permits Deleted.
   The record survives SDK child-directory deletion. Runtime deletion takes its
   own SDK source lock after the manager's collection and outer lease closure.
   Unknown shutdown/deletion cannot replay or retire leases. Exact completion
   removes only original cache entries before transient gates/work retire, while
   backing and persistent bookkeeping remain charged. Five private file/row
   models cover ordering, absence, no replay, accounting and protected records.
   Explicit native resolve_held_branch_deletion now requires caller quiescence,
   the original returned host worker, retained gates and positive original epoch
   collection plus complete SDK row/reservation/directory absence. It performs no
   SDK shutdown/delete or material replay. An operation/request-bound resolution
   records ResolvedAbsent separately from SDK Deleted, including disappearance
   during Collecting/Collected. Exact recorded lookup precedes current inventory
   and never changes requests. Schema-one records retain their 64-KiB limit and
   exact omitted-field shape; only the new resolved schema two permits 80 KiB.
   A reserved 32-MiB/four-descriptor material-control job works during quarantine,
   retaining one ordinary observer alongside unresolved work. Completion retires
   temporary leases only after original cache retirement; backing/bookkeeping and
   any wider quarantine remain. Five additional private models cover these gates,
   resolution histories, compatibility and control accounting. These private
   schemas/limits still need public reader/package negotiation before activation.
   The checked resolve_held_branch_deletion request now binds full original
   completion, the exact held root receipt, a distinct operation/canonical request
   digest and explicit quiescence. The engine matches the retained completed
   context and excludes its active borrower before touching the deletion journal.
   Protocol two/Port/Elixir carry a required nonnullable positive-absence proof
   under exact policy/domain/platform correlation and zero output. Request and
   proof caps are 68 KiB and four KiB; the 30-second control entry remains usable
   while ordinary admission is unavailable. The existing finite branch terminal
   allowance preserves both observers. Synthetic cross-reader/helper models and
   the existing private deletion state models establish no SDK qualification.
   This entry performs no SDK delete or filesystem cleanup and releases neither
   dependency nor backing. Frozen managed intent/version and proof now use
   selective v34, preserving prior envelope bytes. Both Memory and PostgreSQL
   accept the request before IO and atomically retain proof while releasing only
   the ordinary child reservation; dependency/backing state remains. Generic bare
   absence and uncertain-to-deleted writes cannot bypass this boundary. Public
   Machines.resolve deleted resolution preserves the native helper/controller
   fence through acceptance, original-owner proof and guarded final commit. Its
   finite deadline follows fencing, claims, IO and commit admission; explicit
   retries preserve the accepted request. Parent/dependency history and immutable
   child creation/material stay unchanged. Explicit continuation/residual-cleanup
   routing and ordinary qualification remain required before native activation.
   Shared SQLite absence queries now accept the same caller deadline/cancellation
   through their query progress guard; the legacy convenience entry retains its
   existing default budget. A read-only cancellation model covers both boundaries.
   Explicit continue_held_branch_deletion now handles an original collected child
   whose material remains, including uncertainty before the stopped-row update.
   Positive original epoch collection and exact held material precede a frozen
   operation/request grant. Schema three records Finishing before stopped-row CAS
   and one final SDK deletion. Only the same unentered Finishing request can
   continue; Deleting never retries. Normal and continued deletion share the
   final stopped-material checks, SDK lock closure, one-shot entry and positive
   absence completion. Resolution preserves the continuation binding and remains
   distinct from SDK success. Original work/parser/gates stay retained, with one
   reserved control allowance following actual owner-thread return and a fresh
   cleanup budget. Backing/bookkeeping and wider quarantine remain. Eight additional
   private models exercise these boundaries without an SDK deletion. Earlier
   journal schemas retain their exact omitted-field shapes and limits; public
   reader/package/store negotiation and ordinary qualification remain required.
   Final entry also rechecks bounded SDK dependency inventory and the pinned
   fork-child cache shape (absent or source link). Private pack directories reject
   before SDK mount cleanup, keeping this no-launch branch grant truthful and
   preserving source/sibling volumes. Private callback models cover both guards.
   Explicit cleanup_held_branch_deletion now removes residual original child
   files after positive original collection and SDK row/reservation absence.
   The actual directory descriptor remains pinned across SDK deletion, preventing
   inode reuse before acknowledgement. A separate protected Cleaning/Cleaned
   record freezes the cleanup request, original intent and parent identity;
   primary schemas one/two/three retain their shapes. Bounded descriptor-relative
   removal preserves source/sibling link targets and never retries SDK deletion.
   Same-request partial removal can continue with a fresh budget; matching primary
   absence proof can close out the cleanup audit without touching new material.
   A distinct resolved-absence proof precedes exact cache/transient retirement.
   Original work/gates/parser admission and reserved material control remain
   charged through actual worker return, leaving an observer available; backing,
   persistent history and wider quarantine remain. Eight private non-VM models
   cover these boundaries. Released/restarted children and pre-handoff disposal
   are outside this original-held-context path and remain required.
   Checked continuation and residual-cleanup requests now bind the full original
   held completion/root, a distinct action, fresh operation/canonical request digest
   and explicit quiescence. Exact retained completion and no active borrower are
   required before entering the original deletion path. Continuation acknowledgement
   comes only from the protected Deleted record with the same frozen continuation;
   positive absence cannot assert SDK success. Cleanup returns its action-bound
   absence proof. Protocol two, Port and Elixir distinguish both operations and
   nonnullable outcomes, require Delete capability plus immutable branch approval,
   correlate domain/platform/request and reject streams. The existing 68-KiB request,
   four-KiB proof and 30-second control limits apply, preserving both observers under
   finite terminal buffering. This transport foundation adds no public machine API,
   durable action grant, codec version or activation marker. Managed acceptance,
   version freezing, separate action/proof retention and explicit public routing
   remain required; Machines.resolve must keep its no-delete/no-cleanup contract.
   Managed action acceptance now freezes each continuation/cleanup request under
   the claimed version before helper IO, independently of observational resolution.
   Selective v35 retains both action slots and typed acknowledgements while older
   envelopes omit the new nil defaults exactly. Memory and PostgreSQL guarded
   completion release only the ordinary child reservation. A completed action can
   preserve earlier pending requests as history without treating them as completed
   or allowing a late different result to rewrite deletion. Generic resolve cannot
   consume an action acknowledgement. Explicit Machines.continue_deletion/4 and
   Machines.cleanup_deletion/4 now hold one captured helper/controller fence through
   expected-version claim, request acceptance, bounded IO and guarded final commit.
   Each checks the exact accepted scope, original platform/action/request, typed
   acknowledgement and zero output. A single deadline begins before fencing.
   Missing/late results, renewal failure during IO and post-effect guard conflict
   retain uncertainty and the child slot; a definitive pre-entry rejection keeps
   not-dispatched evidence. Historical saved acknowledgement returns without helper
   IO. HTTP rejects both native-only entries before dispatch. Shared native
   admission requirements and ordinary package qualification remain required.
   Explicit native release_branch_backing now requires positive caller
   quiescence and host backing-removal confirmation, original completed registry
   context, ordered source/child gates, original source absence/epoch quiescence
   and original child collection. SDK rows, creation reservations and both original
   directories must be absent. No cleanup/GC, SDK action or dependency retirement
   is dispatched. A separate protected receipt binds original completion/boot/
   plan, publication, request and exact native backing charge. Synchronization
   precedes material-accounting release; known exact proof can acknowledge a
   prior result without touching recreated material. Result metadata/history,
   other branches and global quarantine remain. Only explicitly released
   completed entries may drop normally at registry shutdown. Seven private
   non-VM models cover absence, host confirmation, collection, proof/record
   integrity, lost acknowledgements, cancellation, control and sibling accounting.
   Native release still depends on host confirmation for backing outside the
   expected namespace, matching the public HTTP contract; path absence is not a
   forensic assertion that no file was moved. Public retirement/storage-release
   routing and durable dual reservations remain required.
   Public branch orchestration now assigns each backend reference to its
   exact source or child record for preflight, creation, completion and release.
   Explicit resolve/retire/storage-release use the shared native authority fence,
   pinned owner/epoch, positive helper quiescence and worker claim through their
   final guarded store transaction. Paired observations preserve one pin; a stale
   or unavailable pin cannot resolve a replacement between source/child queries.
   HTTP keeps its existing client and store transitions. Seven transport models
   and four public/store coordination models cover scope, pinning, stale/busy/
   competing authority and retained/released public accounting. Their validated
   public branch records and semantic adapters do not supply native assignment
   enrollment, child/material proofs or live qualification. Native wire routing,
   durable branch authority/codec and engine backing-release acknowledgement
   remain required before activation.
   Source-only branch_preflight is now a protocol-two operation routed by the
   Port adapter to the existing shared-engine original-owner preflight. A material
   receipt, matching domain, branches feature version and at most 30-second budget
   are required. Replies must be zero-output running observations with PID,
   resources and explicit offline/unmapped/unmounted configuration; qualification,
   creation and stream results cannot substitute. The probe consumes work, not
   reserved observation/control admission. Scoped branch_source construction and
   reply decoding retain original source identity/resources; current packages
   still reject before dispatch. A shared synthetic fixture, three Rust protocol
   contracts, one helper peer and four Elixir contracts cover this path without an
   SDK fork or source qualification. Creation, child observation/absence/release,
   durable branch authority and full ordinary acceptance remain required.
   The shared engine now exposes create_branch with a typed BranchCreateRequest
   containing exact source/child/operator approval and optional initial release.
   Held children reject initial activation; non-held children require its distinct
   operation/request before admission. The driver composes protected intent,
   retained worker preparation, material publication/first boot/initialization,
   optional initial release and original manager handoff under one budget. It
   never invokes a convenience SDK fork or cold fallback. Errors after protected
   intent publication remain uncertain; existing pending state/gates prevent
   replay and retain original work/backing. Exact completed lookup precedes fresh
   admission and reads only the original registry, with no current SDK inventory
   or owner reconstruction. It checks source material head, full child/policy/
   activation and duplicate/conflicting results; None proves no absence. One
   reserved material-control allowance permits bounded lookup during quarantine
   without freeing backing/history. Six private models cover these boundaries;
   ordinary end-to-end workflow qualification and Port/durable integration remain
   required before native branch activation.
   Protocol two now carries typed create_branch and inspect_branch_completion
   requests/results through the helper and shared-engine adapter. Both require
   the branches feature and an exact immutable operator catalog entry; an ID
   alone cannot approve a different backing/resource policy. Creation uses the
   work lane; historical completed lookup uses reserved observation admission.
   Typed source publication, child origin and optional initial-release evidence
   preserve engine hash algebra and exact request/platform correlation. Proofs
   consume bounded control storage, including when event output is stalled.
   Synthetic held/released peers and engine/wire fixtures prove these contracts
   without a live fork. Elixir now checks the same canonical intent/publication/
   release hashes and typed results, request/domain/platform correlation, distinct
   creation/lookup kinds and zero output. Helper catalogs forward only under the
   negotiated branch feature and bind exact public policy resources plus each
   approved source profile's host overhead. At most 32 policies by 32 distinct
   profile overheads are approved; duplicate variants or changed backing resources
   under one policy ID reject. The allocation floor cannot substitute for profile
   accounting. Branch-bearing helper configs have a 512-KiB bound for this finite
   catalog; configs without it retain the 64-KiB limit. Durable branch
   authority/history/codec/dual reservations, public
   backend create/lookup routing and ordinary platform qualification remain
   required. Current public capabilities stay disabled.
   Actual SDK boot/initialization/release/handoff/restart qualification, public
   fresh-budget held release/deletion, entered pre-handoff child disposal,
   unproved residual cleanup, public continuation/resolution/cleanup/proof/store routing,
   backing retirement/replacement, multiple-
   child source qualification and public proof/store/codec integration remain pending. These
   new persistent limits must be negotiated before public branch admission.
   No public capability is enabled.
   The clean shared-RAM
   strategy must be frozen/qualified before dispatch; paged guardian mode rejects.
   SDK source-lineage updates and copied child labels require distinct material/
   ownership publication. Durable dual reservation, existing-child ordinary
   qualification, enrollment/held release, histories, bridge and ordinary acceptance
   remain required; this initial boundary does not complete P8.4.
5. Extend capture/export/branch histories and material-transition validators
   without adopting unknown results or replaying mutations. Model late proof,
   partial publication and missing child deterministically.
   Typed branch source-publication and child-release links now compose with
   growth/capture/resolution histories in the Elixir material reader. The chain
   checks exact prior receipts, operation-ID uniqueness, known immutable hashes,
   checkpoint heads, platform/lineage continuity and disk backing. Child release
   is a distinct root-linked sealed history, matching the current engine journal;
   it cannot authorize later growth/capture/branch mutations. Branch identities
   require their complete chain. Branch histories have the engine's 1,024-link
   ceiling; existing branchless histories keep their 288-link bound. Two synthetic
   platform fixtures pass every prefix through the actual Rust journal validator
   and Elixir reader without SDK entry. Selective v29 codec support retains these
   typed links in attached command evidence and rejects older-envelope
   substitution; existing records keep their prior bytes. Initial native Store
   admission now freezes independent child ownership, the exact source receipt,
   public source key/fingerprint, profile policy and optional initial-release
   request. Memory's existing guarded two-record transaction reserves both the
   ordinary child and extra allowance; duplicates preserve the frozen request,
   stale guards reject and uncertainty retains both reservations/source lock.
   Undispatched cancellation atomically retires the source index without claiming
   SDK absence or releasing entered work. Source native branch history is
   append-only, folds into the material head and reaches attached command proof.
   Selective v30 records retain these new fields while older HTTP/native bytes
   stay unchanged; older envelopes reject native branch semantics even if the
   new default fields are stripped. A fresh BEAM decodes the fixed vocabulary
   without native tools. Public source restrictions, including the exclusion of
   growth on checkpointable sources, remain intact. Guarded native completion now
   requires the exact original typed completion plus two positive current running
   observations, with the original source PID/birth. One source/child transaction
   appends source publication, records the independent immutable child root and
   current held/released material, then unlocks the source without releasing backing.
   Ordinary completion retains the original deadline; an unknown result requires
   explicit kept resolution with that same proof/observation bundle. Missing
   lookup, bare Machines and absence atoms grant neither readiness nor capacity.
   Frozen requests and recorded completion cannot be rewritten by updates.
   Completed children retain their exact root/release chain through stopped
   observations, codec reading and ready-child command attachment; source commands
   use v29 while commands retaining a native child assignment use v30. Held-state
   substitution and lost release history reject. The same synthetic contracts pass
   Memory and encrypted PostgreSQL, including rollback of source, child and resource
   projections together. Explicit held-release store acceptance now freezes the
   public version, distinct request/fresh deadline, current source head and both
   original process identities. Both adapters lock source and child in one
   transaction; child-guarded advancement preserves both locks on uncertainty.
   Exact explicit release proof plus current observations alone can record
   release or resolve an unknown attempt; neither frees backing. Creation
   completion/root stay immutable, while the explicit transition advances child
   material and reaches command history. Sibling-source advancement binds the
   latest source receipt and concurrent source work rejects without changing the
   sibling. Selective v31, older-envelope rejection and fresh-BEAM reading retain
   this intent/proof without changing prior v30 bytes. Shared Memory/PostgreSQL
   models cover completion, unknown resolution, stale guards, crossed PID/material
   proofs and paired intent/result rollback. A checked engine release entry now
   compares the entire original held completion/identity/source before work.
   Completed-result qualification retains original context/enrollment and cannot
   dispatch SDK work or reconstruct inventory ownership. Both protected
   completions and collected original work may promote only an existing owned
   handle and retire transient work; missing result grants no absence/retry
   authority or backing release. Protocol-two release_held_branch and
   qualify_held_branch_release now carry the frozen completion/current source/
   distinct release request through the helper with exact immutable approval.
   Dispatch uses work; qualification uses reserved observation/control. Requests
   and distinct zero-output results bind identity, request, domain and platform;
   proofs use bounded branch control storage and cannot use ordinary controls.
   Shared synthetic macOS/Linux engine/wire/Elixir and helper catalog/lane tests
   grant no live SDK qualification. Source-scoped backend and Runtime routing now
   obtain original proof and positive current source/child observations under one
   owner/deadline, then consume paired completion or explicit kept resolution.
   Native assignment approval binds inherited metadata and original policy;
   ordinary image creation cannot substitute. Future descriptor enrollment needs
   native_branches:1 plus managed_branches:1, which current stores do not advertise.
   A separate qualify_branch_child_absence protocol entry now requires exact
   retained completed context, original boot collection, current epoch quiescence,
   both gates and bounded SDK row/reservation/directory absence. It dispatches no
   SDK deletion and releases neither dependency nor backing capacity. Exact
   request-bound zero-output proof uses reserved control admission and the same
   caller budget; typed cross-reader synthetic fixtures cover held and released
   children on Linux/macOS. No proof is issued from inventory or bare row absence.
   Backend child-absence routing now requires successful helper quiescence under
   the captured owner/epoch, an approved deleted-child assignment and the exact
   original completion/head. Runtime carries the native authority fence through
   final paired retirement. The Memory and PostgreSQL stores bind proof to saved
   child head/completion/fingerprint/version and retain immutable proof/original
   version while atomically retiring only its source dependency. Stale child
   results reject even under a current source guard; all extra backing remains.
   Selective v32 preserves v30/v31 bytes and fresh-BEAM reading. Older experimental
   retired states remain readable without becoming new proof; explicit fresh
   ratification is required. Complete partial/absent creation resolution,
   released/restarted-child deletion, normal store replacement, public activation
   and ordinary end-to-end SDK/platform/source qualification remain. Prepared-only
   v36 history and public routing are implemented as described above.
   The codec reader advertises no branch-store capability or native admission.
   The checked release_branch_backing protocol entry now binds the full original
   completion, expected source/child tombstone heads, explicit quiescence and host
   backing-removal confirmation to a canonical request digest. The engine checks
   exact retained completion and absence of an active original borrower before
   admission and again inside the accounting worker. Its existing protected
   ledger acknowledges only that original charge; lost replies cannot authorize
   another charge release. Requests are bounded to 80 KiB, proofs to 68 KiB and
   work to 30 seconds. This accounting mutation uses reserved control admission,
   exact approval/domain/platform correlation and a zero-output terminal, including
   while ordinary admission is unavailable. Rust and Elixir share synthetic
   held/initial/explicit-release fixtures. Native backing intent acceptance now
   locks source/child under the source guard and exact child version. Both must
   be durably deleted, all dependencies retired and original publication/typed
   retirement retained. Selective v33 saves a stable request across later claims,
   preserving earlier bytes. Both Memory and PostgreSQL retain all backing while
   pending and close only the extra reservation with a matching typed proof in a
   paired transaction. Public release_storage now accepts the native request
   after successful helper/controller fencing and before IO, preserving that
   fence through final guarded closure. A native-only release_branch_backing
   backend entry binds independent source approval and the exact accepted child
   scope, saved heads and request. One finite budget covers fencing, acceptance,
   observation and commit admission. Missing/late/wrong results preserve the
   request and every charge; explicit retry keeps its original ledger identity.
   Saved completed acknowledgement reads are idempotent without helper IO. HTTP
   retains its original two absence observations and store variant. Deterministic
   public/backend peers cover both fence-held store writes, draining cleanup,
   missing reply retry, final guard conflict, deadlines and unavailable/stale
   owners. Ordinary qualification and remaining resolution/replacement gates stay
   required; no store marker or native feature admission is enabled.
   Original unbooted disposal now also uses that backend entry, assigned to the
   source rather than a fabricated child Machine. Its full-disposal wire request
   selects release_unbooted_branch_backing and requires the original epoch,
   exact source head/child root, retired dependencies and host confirmation.
   Selective v39 persists a stable request and distinct backing_pending state;
   only its matching native acknowledgement closes the paired extra reservation.
   Disposal/retirement history and earlier v37/v38/legacy bytes remain immutable.
   One fence/deadline covers acceptance, dispatch and final guarded commit; retries
   retain the original request and cached completion needs no helper IO. Memory,
   encrypted PostgreSQL and public semantic models cover both hold/provenance
   combinations, missing replies, failed commits and draining. Other partial/
   boot-entered origins and ordinary SDK/platform qualification stay required.
   The engine now also has explicit resolve_ready_branch_completion for an
   original pre-handoff result whose producer budget expired. A fresh bounded
   original resolution token can requalify completed initialization/release and
   transfer its actual original manager, enrollment and backing. Protected
   lifecycle/full creation/live source and child facts remain mandatory; entered
   phase flags cannot invent completion. Exact released-head promotion requires
   an already owned root/head. No SDK or guest action is replayed, and historical
   lookup remains observational. Protocol-two resolve_ready_branch_completion
   now carries exact creation plus positive quiescence through the branch catalog,
   reserved control/terminal path and shared engine. Native-only
   resolve_ready_branch/3 routes public kept resolution through one controller/
   helper fence and finite deadline, requiring fresh source/child observations
   before the paired existing v30 completion. Historical inspection remains
   read-only. Missing/late/wrong proof or a failed commit retains source exclusion
   and all reservations; retry keeps original creation identity and cached saved
   completion needs no helper IO. Draining permits retained recovery. Cumulative
   encoded payload/framing budgets and separate 30-second observation limits apply
   across the three exchanges. Ordinary SDK/platform qualification, earlier
   partial phases and remaining deletion paths stay pending.
   Ordinary delete now also selects the original released-child context, sharing
   the held collector's protected entry, original manager/enrollment, collected
   stopped row and one-shot final SDK deletion. Its exact initial/explicit release
   binds the current head and private native schema four; legacy schemas retain
   their encodings and 64/80-KiB bounds. Released records have a 160-KiB bound and
   a second retained metadata lease. Legacy held resolution/continuation/cleanup
   explicitly reject this origin. Host/store guards now require distinct native
   evidence for every completed-branch delete uncertainty; bare absence cannot
   resolve either origin.
   The distinct checked released absence request/proof now binds full original
   completion, exact release/current head, separate operation and canonical hashes.
   Retained original collection and bounded row/reservation/directory absence
   precede native schema five. Completed ordinary deletion reacquires paired gates
   if its transient leases already retired. Earlier encodings remain unchanged;
   source/snapshot/backing is retained. Protocol-two/Port use an exact-policy,
   30-second control entry with 132-KiB requests, four-KiB results and zero output.
   Public/store consumption now selects distinct held/released grants and typed
   proofs under the same captured helper/controller fence and absolute deadline.
   Released grants freeze claimed management/delete versions, exact completion,
   release and current head before IO; selective v40 preserves earlier encodings
   and older envelopes reject this variant. Memory/PostgreSQL atomically retain
   acknowledgement and retire only the ordinary child reservation. Source history,
   dependency/backing charges and immutable child creation/release remain separate.
   Missing/mismatched proof, stale guards and explicit retries preserve the saved
   request. Shared-engine released continuation now uses a distinct checked
   request/proof and reuses the held collector/final SDK worker. Schema six freezes
   the exact continuation before stopped-row normalization and final entry; only
   the same unentered grant resumes, while Deleting never replays. Positive
   absence after unknown continuation preserves the grant in the intent digest.
   SDK success and absence remain distinct, earlier encodings stay exact and all
   backing remains retained. Protocol-two/Port use Delete capability, the original
   approval catalog, finite reserved control/terminal capacity and zero output.
   Durable/public released continuation now persists a distinct grant in the
   existing continuation slot before IO and consumes only its exact SDK-success
   proof under the same helper/controller fence and absolute deadline. Selective
   v41 freezes claimed management/delete versions, original completion, release
   and current head while preserving earlier encodings. Old v35/v40 envelopes reject
   the new variant. Both stores retain an independent pending observational grant
   after SDK success and a pending continuation after positive absence; absence
   cannot become SDK success. Only the ordinary child slot retires and independent
   dependency retirement preserves both histories. Released residual
   cleanup now has a distinct checked native/Port request with the existing
   positive-absence proof. Shared descriptor-relative removal requires original
   collection, row/reservation absence and a pinned original root; it preserves
   source/sibling links and never invokes SDK lifecycle. Released cleanup schema
   two and main proof schemas retain exact request/continuation history; only the
   same recorded grant resumes partial cleanup or finishes an already removed
   directory. Matching primary completion finishes only its audit and never
   traverses recreated material. A third retained 128-KiB metadata allowance is
   reserved before uncertainty, funding cleanup during ordinary quarantine.
   Earlier held ledger bytes/bounds stay exact. Durable/public cleanup now saves a
   distinct released grant before IO and consumes only its matching typed absence
   proof under one helper/controller fence and absolute deadline. Selective v42
   preserves claimed management/delete versions, full completion/release/current
   head and pending independent histories. Both stores retire only the ordinary
   child reservation; mixed cleanup/observation/SDK completion routes preserve the
   other original grants without authorizing a later cross-route completion.
   Reader-first upgrade is required; v35/v40/v41 reject the new grant and earlier
   bytes remain exact. Restarted/pre-handoff deletion and ordinary SDK/platform
   qualification remain required. Normal original released-child stop now shares
   deletion's retained-manager collection primitive. It binds the actual manager,
   enrollment, paths and release, records pending collection before SDK stop, and
   requires positive collection plus an exact stopped-row acknowledgement before
   active manager retirement. It retains protected material/release history and
   source/backing for regular restart. A later authorized current material head
   must still verify against its original child. Deterministic actor/row checks
   cover returned errors, incomplete collection and stale/crossed acknowledgements;
   actual stop/restart/delete and replacement-owner qualification remain required.
   A normally retired original manager can now enter the existing protected
   deletion path for its exact original released head, including that unchanged
   head after an ordinarily completed restart/stop. No active Engine/runtime
   handles, canonical stopped state and positive original epoch collection precede
   intent entry under the paired gates. Pending restart/collection actors block
   admission. The existing final collector, one-entry SDK deletion and explicit
   continuation/absence/cleanup journals retain all source/snapshot/backing state;
   no new wire/codec/proof shape is needed. Selection preserves existing lifecycle
   behavior for later heads, active handles and missing historical material,
   without granting retired-original authority. Their complete recovery,
   replacement-owner and pre-handoff deletion remain required. Ordinary SDK start
   now retains a finite charged boot slot before dispatch and attaches only the
   original returned enrollment. Pending slots grant no collection authority.
   Ordinary stop, stale-start cleanup, deletion and entered-capture stop fence the
   exact SDK entry until return, then require positive current-boot collection.
   Exact stopped acknowledgement retires only that runtime metadata, while
   uncertain results retain it. Stopped natural exits no longer skip cleanup of
   the current returned SDK handle. Replacement start validates source/mount
   restrictions before cleanup and cannot overwrite a previous unresolved slot.
   Metadata exhaustion preserves reserved control/observer headroom. These
   same-engine foundations still require ordinary package/platform qualification
   and do not resolve broader partial/unknown material or helper replacement.
   Port stop now captures/caps an absolute deadline before adapter selection and
   passes it with the same cancellation through stop_with_budget, inspection,
   original/current collectors, SDK entry and final observation/retirement.
   Pre-entry expiry keeps NotDispatched; late return/observation stays uncertain.
   Failed final observation retains the ordinary boot slot and active handle;
   successful cleanup removes both so retries cannot strand an inactive handle.
   Source/mount/ownership guards remain before SDK mutation. Existing deadline/
   cancelled wire errors preserve dispatch evidence and public vocabulary without
   protocol/codec evolution. Ordinary lifecycle qualification remains required.
   Original-child collection after a returned Collecting deletion now has a
   separate checked shared-engine control. It binds the exact original completed
   context, held/initial/explicit-release head and quiesced request. A distinct
   bounded protected ledger freezes request/worker before original-manager stop;
   same-original opaque collection precedes its collection-only acknowledgement.
   SDK return alone grants no proof. Both held and released deletion reserve an
   extra 128-KiB metadata lease before original entry, retaining all gates, source
   leases, work, backing and public capacity through collection uncertainty.
   The new acknowledgement changes neither SDK rows nor primary journal schemas,
   readiness, absence, dependency or backing authority. Existing continuation
   still requires positive original collection and enters only an unentered final
   SDK delete. Matching historical acknowledgement lookup avoids current child
   namespace traversal; missing published ledgers cannot be re-enrolled.
   The distinct request/proof now routes through Port control and a fenced
   Machines.collect_deletion/4 public action. Separate v43 durable acceptance and
   completion preserve delete uncertainty, ordinary capacity and all dependency/
   backing charges. Exact saved proof returns without helper IO; old codecs retain
   exact bytes and cannot carry collection history. Ordinary SDK, package/platform/
   source and consumer qualification remain required before activation.
6. Run ordinary independent checkpoint restores, supported registry export/import,
   sibling branch independence, explicit held release and dependency cleanup on
   every supported platform/source combination. Use normal APIs and owned cleanup;
   no owner-loss, persistence interruption or destructive external CLI race.

Exit gate: saved-state APIs preserve exact artifact/memory/disk semantics and
source/child ownership, including every auxiliary resource and unknown reservation.

## P9 Full parity audit, upgrades and public documentation

Primary areas: shared contracts, ordinary native proof runners, evidence, package
consumer CI, examples, public feature guides and distribution review.

1. Close every matrix/arity row with implementation and test references. Audit
   invalid combinations too: unsupported user/source/platform/store requests must
   reject before reservation/dispatch. Any unresolved required row blocks parity.
2. Run appropriate Rust/Elixir/Memory/PostgreSQL checks and HTTP regressions. Verify
   complete clean source inventories, finite resource budgets, control isolation,
   framing, redaction and selective legacy/new codec behavior.
3. Rebuild exact Linux/macOS native packages and run public current/minimum
   consumers without Rust, plus HTTP-only consumers without native assets.
   Execute feature-specific ordinary campaigns in approved domains and record
   exact source/build/asset/policy/tool/fixture identities and actual restrictions.
4. Test ordinary draining, graceful Runtime replacement with a surviving store,
   stopped compatible helper upgrade and retained optional-feature histories.
   Approve exact replacement packages; never relabel old receipts or automatically
   transfer authority. Test reader-first codec upgrade and incompatible rejection.
5. Update public setup/examples and feature guides to identify actual Port support,
   platform limits and native prerequisites. Add parity evidence and completion
   audit separately from the historical offline migration. Document CLI exclusivity,
   optional tool/source inputs and remaining distribution approval work accurately.
6. Verify every ordinary runner selects ordinary/public mode explicitly and cannot
   trigger deferred fault tests. Keep crash qualification false, historical fault
   failures visible and publisher signing/provenance/license approval separate.

Exit gate: all required HTTP-parity rows implemented and ordinarily qualified
within the same public limits, with preserved HTTP compatibility. Rustler/Kubernetes,
live crash/CLI-race validation and distribution approval are not completion claims.

## Execution and evidence rules

P0 precedes enabling features. P1 and P2 establish the identity/version/resource
foundation; P3 and P4 precede networked OCI/launch workflows, and P5 precedes P6.
P7 and P8 require P1 material proofs and P2 bounded artifact/job infrastructure.
P9 follows all feature gates. A passing early phase does not establish full parity.

Do not run live helper/BEAM loss, forced termination fault campaigns, pre-main
boot pauses, watcher failure injection, live durable interruption or destructive
independent CLI writers. Deterministic non-VM models, explicit request cancellation,
normal lifecycle shutdown and graceful stopped-helper replacement are allowed.
Do not use unfiltered native test commands that include deferred campaigns.

Keep receipts, keys, credentials, native packages and raw private proof logs under
ignored private locations. Commit only reviewed source/docs and sanitized evidence.
Do not overwrite historical evidence with changed-package results. Scope/resource
constraints discovered during implementation stay explicit; no silent HTTP reroute,
no reintroduced patches and no unsupported-feature success placeholders.
