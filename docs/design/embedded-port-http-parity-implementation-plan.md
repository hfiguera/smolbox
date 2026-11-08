# Implementation plan for embedded Port HTTP parity

Status: implementation in progress, October 13, 2026. Implements the
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

1. Implement approved checkpoint restore into a fresh authenticated creation
   intent. Preserve CPU/runtime/platform/topology compatibility and forbidden
   dependency checks. Starting after a later stop does not reapply captured RAM.
2. Add checkpointable startup, preflight and bounded capture using SDK APIs.
   Preserve idle offline bare-source limits, controller-private streamed artifacts,
   extra resource floors, immutable source authority and source resume on success.
3. Implement stopped-source export with exact container/bare preservation rules
   and approved registry destination/token/receipt. Select the bounded approved
   host-conversion or fully enrolled auxiliary-VM approach established in P0;
   never reuse the private fixture exporter as qualified product behavior.
4. Add branch source/absence/create/inspection/hold/release with authenticated
   source and independent child proof, atomic dual reservation, ordered gates and
   owner-epoch enrollment for forked VMMs. Keep one-leaf/offline/bare restrictions,
   extra backing allowance and parent dependency checks through child retirement.
5. Extend capture/export/branch histories and material-transition validators
   without adopting unknown results or replaying mutations. Model late proof,
   partial publication and missing child deterministically.
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
