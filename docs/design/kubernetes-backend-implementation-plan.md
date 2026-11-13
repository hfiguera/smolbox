# Kubernetes backend implementation plan

Status: proposed, November 13, 2026. Follow the decisions in
[the design](kubernetes-backend.md). **The long-term goal is feature parity with
HTTP and Embedded through the same SmolBox public APIs and behavioral contracts.**
Phases 0–7 deliver the first milestone: a development preview of disposable
execution on one enrolled Linux/K3s node. Later milestones extend that foundation
to production operation and full domain capability coverage. Existing backend
behavior must remain compatible throughout.

Track delivery in [implementation progress](kubernetes-backend-progress.md) and
the [versioned parity matrix](kubernetes-backend-parity.md). Phase 0 runtime
qualification has passed in the dedicated lab; library phases remain pending.

## Starting point

Already available:

- `SmolBox.Backend` operations and budgets, HTTP/Embedded adapters, target
  normalization, managed orchestration, authenticated store/codec boundaries,
  and artifact-store staging/collection.
- An isolated [single-VM K3s lab](../kubernetes-lab.md) on `ssh linux`, with the
  real upstream SmolVM runtime and pinned dependencies.
- A passing upstream runtime smoke, binary/nonzero-exit/physical-cleanup evidence,
  and ten manual offline harness checks. The lab is committed separately from
  the future backend and is not run by CI.

Still absent: Kubernetes target configuration, API client, exec transport,
source admission, durable Pod receipts, backend cleanup proofs, and public
Kubernetes execution tests. The current smoke is not a substitute for them.

Deliver phases in dependency order. Each phase should be a reviewable change
with focused tests and an explicit exit gate. Do not combine speculative later
features into the first backend PR. No phase below authorizes changing the
shared physical host's container runtime or running hostile tests there.

## Phase 0 — Resolve runtime qualification blockers

Primary areas: `scripts/kubernetes/`, `docs/kubernetes-lab.md`, new evidence files,
and read-only inspection of upstream source/distribution.

1. Check tag `v1.34.0` against the downloaded archive and reference checkout
   `f9e93d8f`; record archive/shim hashes, kernel/rootfs/template identities,
   actual sandbox sizing and container rootfs-copy behavior. Do not transfer
   Embedded/HTTP package qualification to this archive.
2. Measure the fixed 2-vCPU/1-GiB VM and actual disk templates. Record measured
   host memory/headroom, runtime paths, rootfs-copy/cache allowance, and guest
   cgroup behavior. Specify the single approved profile, container requests,
   limits, RuntimeClass overhead, and store reservation without undercounting
   the VM or promising dynamic sizing. Bound concurrency to one.
3. Provision a dedicated namespace and administrator-owned default-deny policy
   before the next execution. Prove the guest's network takes the CNI enforcement
   path. Test DNS, public/cluster/node/metadata destinations and IPv6 behavior
   using bounded controlled endpoints. Node exceptions must be closed by a
   qualified additional restriction or declared a release blocker.
4. Select and digest-pin a public Linux amd64 image containing Python 3 and a
   neutral keeper. Verify `/workspace`, image environment, approved user/security
   context, no automatic workload restart, and the helper prerequisites. Keep
   the existing BusyBox runtime smoke as a separate lower-level baseline.
5. Prove the exact WebSocket v5 exec negotiation through the lab API, separate
   binary channels, successful and nonzero Status forms, and bounded connection
   closure. Preserve the observed CloseIO race as an explicit EOF limitation.
6. Specify node-evidence capture/verification for Pod UID → all CRI sandbox IDs
   → original VM processes/records/directories/shares. Record what cannot be
   proven after lost mappings, node reboot or observer interruption.

Exit gate: a checked-in qualification report and fixed target policy, including
offline probes and accurate reservation requirements. If offline enforcement or
positive cleanup evidence cannot be provided, stop release admission work at a
disabled experimental adapter. Do not relax those contracts to get a green run.

## Phase 1 — Add target and persisted ownership types

Proposed areas: `lib/smolbox/kubernetes/{config,binding,assignment,receipt,identity,
cleanup_proof}.ex`; `lib/smolbox/runtime/target.ex`;
`lib/smolbox/backend/{features,reference}.ex`; shared assignment validation.

1. Add strict config validation, redacted Inspect, explicit endpoint/TLS/auth
   policy, enrolled cluster anchor/namespace/node/runtime identities, profiles,
   image catalog, budgets and required NodeEvidence extension. Proposed API names
   in the design are finalized here, with constructor docs and examples.
2. Normalize Kubernetes config to `Runtime.Target` without creating a fake HTTP
   client or Embedded native config. Implement all target clauses explicitly;
   ensure generic HTTP version-based feature inference cannot enable Kubernetes
   features. Preserve the existing public Worker/Client contracts.
3. Define DNS-safe never-reused Pod names, creation nonce, canonical intent and
   digest before reservation. Keep API credentials and process handles out of
   assignments. Define immutable receipt transitions and cleanup-proof authority.
4. Introduce explicit tagged binding/assignment validation so Embedded's
   `Backend.Assignment.record_valid?` and every direct version/creation-field
   check cannot misinterpret Kubernetes data. Inventory call sites with `rg`
   before changing them; do not globally generalize an Embedded proof check.
5. Add Kubernetes identity comparison to Machine and execution validation.
   A Pod UID is not an Embedded receipt or PID; nullable created_at and state
   rules must be validated by backend kind. Container replacement fails closed.

Tests: bad/missing enrollment identities, unsupported options, catalog/profile
mismatch, secret redaction, DNS name limits, canonical intent determinism,
cross-backend assignment confusion, swapped UIDs and container incarnation.

Exit gate: targets and typed authority can be validated offline; no network
effect occurs and no unsupported operation is advertised. Existing HTTP/Embedded
constructor, capability and identity tests pass unchanged in meaning.

## Phase 2 — Extend store authority, codecs and OCI submission

Primary areas: `lib/smolbox.ex`, `lib/smolbox/store.ex`,
`lib/smolbox/store/{codec*,backend_bindings,backend_assignments,record_ops,memory}.ex`;
`lib/smolbox/{execution,execution_spec,execution_validation}.ex`;
`lib/smolbox/runtime/{config,execution_support,native_support}.ex`;
the reference durable-store integration under `examples/`.

1. Add optional execution receipt/cleanup-proof fields, nil for existing records.
   Add a selective Kubernetes codec version, preserving existing HTTP/Embedded
   serialized bytes and old fingerprints. Include corruption and unsupported
   version rejection; never decode new authority as legacy nil assignment.
2. Extend `bind_backend`'s union and complete authenticated assignment scans.
   Reserve capacity, assignment and initial state atomically. Store original
   Pod receipts under claim/version guards and enforce immutable identity.
   Preserve released/deleted tombstones in recovery authority.
3. Define and implement `kubernetes_backend: 1` capability semantics across the
   memory adapter and reference durable adapter/projections. Validate cleanup
   proof before allowing `cleanup: :complete` or reservation release. A backend
   success tuple without a matching proof cannot release capacity.
4. Add disposable OCI identity support to `ExecutionSpec` and replace the public
   `SmolBox.submit` blanket remote-source rejection with explicit eligibility,
   using existing `Source.oci` identity. Gate submission by Kubernetes target
   and store support; keep HTTP disposable remote-source behavior unchanged.
   Preserve exact source approval and fingerprinting instead of aliasing OCI
   to a local artifact.
5. Add explicit zero unknown-outcome retention for this gated disposable path.
   Retain existing positive defaults/ranges and historical encoding. Kubernetes
   requires `retention_ms: 0`; positive retention fails before reservation.
   Do not silently discard an existing retention request.
6. Keep native helper enrollment/recovery separate. Add Kubernetes enrollment
   and startup checks without treating `NativeSupport`'s Embedded-only scanner
   as a generic implementation. Upgrade all shared-store readers before enrollment.

Tests: full store adapter contract for atomic allocation, stale claims, identity
conflict, lost receipt write, tampered projections, incomplete recovery scans,
missing capability, double release, proof mismatch and cross-target binding.
Add byte-for-byte fixtures for old HTTP/Embedded records and new Kubernetes
round trips; unknown schema fails closed. Verify repeated submission retains its
first deadline and conflict identity.

Exit gate: durable authority supports Kubernetes intent and recovery without any
live Pod operations, and existing store adapters without the new marker reject
Kubernetes enrollment. No implicit migration of existing records.

## Phase 3 — Implement bounded object API and readiness

Proposed areas: `lib/smolbox/kubernetes/{client,credentials,pod,observation}.ex`;
`lib/smolbox/backend/kubernetes.ex`; worker health integration.

1. Build the small HTTPS surface using existing dependencies. Validate server
   URL and CA; prohibit cross-origin redirects/auth forwarding. Read rotating
   token files or resolve callbacks within a single monotonic budget. Disable
   automatic POST/DELETE retries. Bound body length before JSON accumulation.
2. Support version/anchor/namespace/node/RuntimeClass/policy reads and paginated
   Pod inventory. Use bounded polling initially; no watch or watch reconnect
   machinery. Classify unsupported versions, denied permissions, incomplete
   scans and transport errors without leaking response bodies.
3. Implement create from the persisted canonical intent, inspect without side
   effects, and start as initial readiness observation. Enforce exact RuntimeClass,
   source, admitted template, node and container identity; reject extra injected
   containers or forbidden mutations. Record original UID before further effects.
4. Reconcile a lost create response with one-name GET and full intent comparison;
   never blindly retry POST or adopt by a selector. A changed namespace or node
   drains admission. Pending/image-pull/scheduling failure consumes preparation
   budget; no replacement Pod is created.
5. Implement graceful UID-preconditioned DELETE and bounded object absence
   observation, but do not advertise physical cleanup completion yet. Surface
   finalizer stalls and UID conflicts as unresolved cleanup.
6. Provide administrator examples for namespace/Role/RoleBinding and narrowly
   scoped read permissions. Runtime auth cannot write policies, nodes, classes,
   namespaces, Secrets, or controllers. Do not use the lab's admin kubeconfig as
   the public example credential.

Tests: simulated API peer with persisted server-side state for 201, lost 201,
409/name collision, 401/403, throttling, malformed/oversize JSON, pagination,
pending readiness, sidecar mutation, restarted container, stale namespace/node,
UID-precondition conflicts and finalizers. Assert no second POST after ambiguity.

Exit gate: an adapter can create/observe/delete only its assigned bare Pod under
real restricted credentials. No execution or capacity release is enabled yet.

## Phase 4 — Implement WebSocket exec and fixed guest helper

Proposed areas: `lib/smolbox/kubernetes/{exec,remotecommand,guest_helper}.ex` and
protocol fixtures. Reuse Mint/Mint.WebSocket; do not add a Rust/SDK bridge.

1. Implement verified WebSocket upgrade requiring v5, explicit `workload`
   container, non-TTY channels, bounded frame reassembly, status parsing,
   per-stream ordering, control frames, backpressure and connection ownership.
   Teardown must close the connection when its owning operation task exits.
2. Decode actual Success/NonZeroExitCode Status into byte-exact Result. Separate
   API status from workload stderr. Missing, duplicate/conflicting or malformed
   terminal status cannot become successful exit. Preserve partial output and
   observed exit independently when completion is disqualified.
3. Implement a constant Python helper receiving a bounded length-prefixed
   control message, with no application command/env in URL parameters. Execute
   argv directly with approved environment/workdir and application stdin set to
   `/dev/null`. Do not eval strings or invoke a shell around user input.
4. Keep helper input open through command completion; do not use EOF as message
   framing. Reject public command stdin, user overrides, background and terminals.
   Handle partial writes and backpressure inside the deadline: the lab harness's
   single small synchronous write is not sufficient for general file limits.
5. Recheck UID/container around exec, document the remaining name-addressed exec
   race and enforce exclusive namespace/no-name-reuse assumptions. Connection
   fallback, protocol renegotiation and token refresh must not replay an exec.
6. Implement backend exec_stream callbacks used by Runtime.Observation without
   expanding public interactive features. Deadline/owner loss/output cap closes
   observation with uncertain evidence; it does not claim to kill the process.

Tests: fragmented binary stdout/stderr containing invalid UTF-8; silent exit 0;
exit 7; interleaved streams; malformed/empty status; proxy close; missing exit;
duplicate status; oversize frames/output; stalled producer/consumer; owner death;
weird argv/env characters; application stdin EOF independent of helper stdin;
no replay after upgrade; redaction of application values and credentials.

Exit gate: direct adapter exec preserves actual bytes and exits on the live
qualified image, and induced loss yields uncertainty with no second exec.

## Phase 5 — Implement basic files

Primary areas: guest helper, backend upload/download, `Runtime.Files` integration.

1. Implement bounded path-component walking beneath `/workspace` using directory
   descriptors/no-follow semantics, regular-file checks, exact-size/digest
   upload, same-directory temp files and atomic rename. No archives/symlink
   traversal or arbitrary guest directories.
2. Implement bounded download header/data/digest validation; fail on short,
   extra, oversized or changing contents, and preserve the helper's exit evidence.
   Apply size limits before reads/allocation where possible and independently
   cap the actual received payload. Define empty-file framing explicitly.
3. Retain Runtime.Files staging read-back and ArtifactStore publication rules.
   Artifact-store callbacks and transfers share the existing stage budgets;
   failed collection cannot publish a fabricated success receipt.

Tests: arbitrary binary and empty files, 1-MiB boundary, declared/actual size
mismatch, hash mismatch, interrupted input, temp cleanup through Pod disposal,
atomic replacement, path traversal, symlink parents/targets, directories/FIFOs,
changing downloads, slow callback, and aggregate manifest limits. Confirm the
original guest command is never re-executed to recover a missing output.

Exit gate: live upload → read-back → command → download → artifact publication
works with exact bytes, and corruption cannot satisfy the evidence gate.

## Phase 6 — Add node proof, cleanup and restart reconciliation

Proposed areas: `SmolBox.Kubernetes.NodeEvidence`, a fixed lab node inspector and
lab-only host provider, Kubernetes recovery/cleanup modules;
`lib/smolbox/runtime/{executor,cleanup,inspection}.ex` and coordinator startup.

1. Extract scoped CRI/sandbox/KVM/share observations from the runtime smoke.
   Capture node UID/boot identity, all sandbox attempts for the original Pod UID,
   executable hash, VM paths, PID births and verifier epoch. Persist the receipt
   before exec; verify scoped absence after delete. No global empty-inventory
   shortcut, arbitrary path, kill command or unlink operation is accepted.
2. Implement the bounded lab-only NodeEvidence provider with existing SSH access
   and a fixed inspection program. Secret-bearing connection configuration stays
   outside durable records. Handle truncated/invalid frames, mapping loss,
   stale epochs, PID reuse and node reboot by failing closed. Do not install a
   privileged production agent or grant the application shell access to a
   privileged observer Pod as a shortcut.
3. Add a Kubernetes cleanup branch before every generic not-found/stop path.
   With explicit zero retention, delete even when command outcome is unknown;
   no synthetic stop or recreation. Require API absence plus typed node proof,
   then persist proof and complete/release atomically under existing guards.
4. Reconcile ambiguous creation without created_machine/receipt. Inspect the
   saved intent and enroll the original UID only if full authority matches.
   If the API object is gone and original node mapping cannot be proven, retain
   reservation and report unresolved cleanup. Never sweep by execution label.
5. Add complete authenticated startup scans, old-owner quiescence checks and
   observation-only reconciliation. Dispatching/running records become unknown;
   never re-exec. Respect durable real exits for safe collection; leave missing
   exit/output evidence unknown. Resolve prior deletions under their original UID.
6. Integrate cancellation before/after dispatch, lease loss, cleanup deadline
   exhaustion and draining. An unreachable node or recreated namespace/node
   blocks release. Preserve original errors/results separately from cleanup.
7. Add bounded inspection and redacted telemetry for owned, foreign, conflict and
   unresolved resources. No inspect operation may start a VM or authorize adoption.

Tests: stale Pod replacement preserved, unknown create receipt, replacement
container/sandbox, controller death before POST/after POST/after dispatch/after
exit/before proof write, duplicate cleanup, finalizer stall, unavailable observer,
old proof replay, incorrect node identity, PID reuse, leaked VM/share and corrupt
store scan. Verify reservations stay held for every incomplete proof.

Exit gate: cancellation and restart never replay application work; only owned
UIDs are mutated; positive original-VM cleanup evidence controls capacity release.
Without a working provider the preview rejects admission, rather than weakening
the existing runtime contract to API-only cleanup.

## Phase 7 — Public path qualification and preview documentation

Primary areas: an opt-in `scripts/kubernetes/backend-smoke.exs` (proposed),
runtime/unit/store tests, an example host, Kubernetes backend user guide, updated
lab guide and new exact-revision evidence. No workflow changes.

1. Add the public SmolBox test path, not a second direct-kubectl smoke: configure
   target/store/artifact store, construct approved OCI ExecutionSpec with explicit
   zero retention, submit, await/fetch, collect, and verify cleanup/reservation
   release through the library. Cover both memory development and reference
   durable-store configurations; recovery evidence comes from the durable run.
2. Run success and nonzero-exit cases, binary files/stdout/stderr, silent exit,
   cancellation, output overflow, transfer corruption, lost create response,
   lost exec status and controller restart. Include wrong runtime class/image,
   namespace recreation, foreign Pod/name collision and container replacement.
3. Retain real KVM/process-birth and scoped inventory verification alongside API
   outcomes. Record source commit/tree hashes, runtime/archive/shim/image/helper
   identities, node/guest kernels, network/resource probes, execution/collection,
   node proof and reservation accounting. Failed checks stay failed evidence.
4. Run appropriate existing HTTP/Embedded unit, contract, codec/store and public
   compatibility checks. New Kubernetes unit tests use local API/WebSocket peers;
   they never require SSH or a cluster in the ordinary test suite.
5. Document administrator versus application setup, exact supported versions,
   image/profile contract, manual test commands, TLS/auth rotation, node evidence,
   the stdin limitation, zero-retention semantics and unresolved-cleanup recovery.
   Add a runnable minimal example only after its public API is implemented.
6. Reconfirm the four-hour outer lab limit and shared VM lock before each live
   campaign. Scope remote fault injection to the disposable guest. Preserve host
   baselines and existing Embedded/HTTP workers.

Exit gate: every first-release requirement in the design has exact live evidence
and focused deterministic regression coverage. Publish only as a development
preview limited to the enrolled lab/provider configuration. General Kubernetes
support requires a separately reviewed production node-evidence mechanism and
additional cluster qualification.

## Manual development and verification loop

Today, the runtime lab commands are available:

```sh
python3 -m unittest discover -s scripts/kubernetes -p 'test_*.py'
for script in scripts/kubernetes/*.sh; do bash -n "$script"; done
rsync -a --exclude __pycache__ scripts/kubernetes/ linux:smolbox-kubernetes-lab/
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh status'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh sync'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh smoke'
```

Start a stopped lab with `lab.sh start`; use `lab.sh install` only when
provisioning changes require it. Keep credentials private. For future backend
development on the Mac, use the lab guide's SSH API tunnel and explicit TLS/auth
configuration; add an equivalently bounded tunnel/provider for node evidence.
The controller needs neither Docker nor local Kubernetes nor the SmolVM SDK.

As implementation lands, document targeted `mix test` paths alongside each new
module, then run the relevant existing compatibility suites and `mix format
--check-formatted`. The proposed backend smoke command becomes runnable only
in Phase 7; do not present it as an existing feature. Existing generic project
checks may discover new ExUnit tests normally, but **do not add Kubernetes jobs,
the Python harness, SSH access or cluster provisioning to CI workflows**.

## Dependency order and stop conditions

```text
0 runtime/network/resource proof
  -> 1 types/target
  -> 2 store/codec/source authority
  -> 3 object lifecycle
  -> 4 exec -> 5 files
  -> 6 positive cleanup/recovery
  -> 7 public qualification and preview
```

Do not enable backend admission between phases merely because create or exec
works. Stop release enablement for ineffective offline enforcement, undercounted
VM resources, missing complete store authority, ambiguous command replay,
unbounded transport buffers, or API absence treated as physical cleanup.

## After the preview — Deliver HTTP and Embedded parity

These milestones are part of the long-term implementation direction, outside
the first release. Expand each into a detailed plan before implementation;
dependencies and live evidence determine the delivery order within each family.

1. **Production foundation:** replace the lab-only node evidence provider with
   a reviewed production mechanism; add multi-node enrollment, fencing, recovery,
   qualified resource sizing, measurements and worker operations. Preserve
   uncertainty and capacity accounting during node/controller failures.
2. **Sources and connectivity:** add private registry credentials and rotation,
   broader qualified image/artifact sources, network allowlists and ports.
   Preserve exact source approval, credential redaction and effective guest
   network policy across all provisioning paths.
3. **Retained machines and storage:** add the managed machine API, attached
   commands, stop/start with persistent data, volumes and disk growth. Define
   durable storage/incarnation authority and recovery before exposing lifecycle
   operations; replacing a Pod does not by itself preserve the existing contract.
4. **Extended execution:** add qualified command stdin and EOF behavior, guest
   user selection, broader file policies, startup workloads, background launches,
   logs and terminals. Preserve launch versus exit evidence, command-slot
   ownership and cancellation semantics for every execution mode.
5. **Saved state and publication:** add exports, checkpoint capture/restore and
   branches, including storage dependencies, backing reservations, publication
   and cleanup. Identify and implement required upstream runtime or storage
   changes; Kubernetes snapshot support alone does not establish equivalence.

Create and maintain a versioned HTTP/Embedded/Kubernetes parity matrix as these
milestones begin. For every domain capability, record the public contract,
implementation status, qualification evidence, dependencies and remaining work.
Use shared public API and store/recovery contract tests, supplemented by backend
specific live evidence. A feature remains an explicit unsupported capability
until its implementation and qualification gates pass.

Long-term completion requires equivalent coverage of the HTTP and Embedded
domain capability surface and its observable behavior, with existing backends
remaining compatible. The one-node preview is an intermediate milestone; its
scope limits are not permanent exclusions from that goal. These later milestones
do not broaden the first release or change its manual validation policy.
