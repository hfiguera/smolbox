# Kubernetes backend progress

Status: first development preview qualified, November 13, 2026 (November 14 UTC). Follow
[the design](kubernetes-backend.md) and
[implementation plan](kubernetes-backend-implementation-plan.md).
The goal remains the complete first release, Phases 0–7, with HTTP/Embedded
parity tracked in [the parity matrix](kubernetes-backend-parity.md).

## Phase status

| Phase | Status | Evidence / remaining work |
| --- | --- | --- |
| 0 — Runtime qualification | Runtime gate passed in the dedicated lab | [Exact live report](../evidence/kubernetes-backend-phase0-2026-11-13.json); recipe and constraints below |
| 1 — Target and authority types | Type/validation gate passed | Offline constructors, immutable Pod intent, receipts, node observations, cleanup proofs and target normalization |
| 2 — Store/codec/OCI admission | Store gate passed | Selective v54, atomic allocation, UID receipt transitions, proof-bound release, authenticated PostgreSQL enrollment, gated OCI submission; later lifecycle gates supplied by Phases 4–7 |
| 3 — Object lifecycle | Object API gate passed | Bounded TLS/token client, pinned object enrollment, assigned backend create/observe/readiness/UID-delete and restricted live RBAC; application I/O and cleanup qualified in later phases |
| 4 — Exec | Guarded adapter exec gate passed | Real transaction-backed node capture; saved ready receipts; assigned adapter bytes/exits 0 and 7; lost observation without replay |
| 5 — Files | Assigned file gate passed | Shared Runtime.Files staging/read-back and artifact publication on real SmolVM; bounded sealed helper, corruption and unsafe-path rejection |
| 6 — Cleanup/recovery | Authority gate passed | Version-3 node/kubelet proof, same-host process guard, authenticated startup scans, live durable restart/cancellation and proof-bound release |
| 7 — Public qualification | First-preview gate passed | Real public Memory/PostgreSQL smoke and fault controls; current compatibility suite, package/docs checks and [release audit](kubernetes-backend-release-audit.md) |

The runtime public entrypoints are implemented behind explicit controller,
complete startup-scan, enrolled-node and fresh-idle admission gates. Phases 0–6
have passed their scoped gates; Phase 7 public qualification is complete. This is an opt-in single-node development preview, with broader
HTTP/Embedded parity delivered by later milestones.

## Phase 0 findings and approved development recipe

The release/reference shim engine, task service, recovery service and guest Pod
implementation are identical at the recorded hashes. The general resource
defaults differ between the release tag and reference HEAD; the shim explicitly
overrides its VM CPU/memory values. The report records both source identities.
Installed shim, engine, libraries/kernel and all 791 rootfs file/symlink entries
were compared against the checksum-pinned release archive. Actual disk templates
are 20/10 GiB. No upstream runtime asset was patched.

The pinned Python amd64 platform manifest runs Python 3.13.18, a 2-vCPU guest
with 1,041,912 KiB MemTotal, and the expected 1-GiB memory / two-CPU guest cgroup
values. The qualified security settings drop all container capabilities, disable
privilege escalation, and request RuntimeDefault seccomp. No broad enforcement
claim beyond the recorded observations is made.

The preview uses an administrator-owned `smolbox-preview` RuntimeClass with the
same `smolvm` handler and 250m CPU / 512Mi memory overhead. Container requests
are two CPUs / 1,024Mi: scheduler accounting covers 1,536Mi, matching the store
profile plus its declared host overhead. Only one slot is permitted. Fractional
CPU headroom, shared images/rootfs copying, and disk growth remain covered by
the enclosing 4-vCPU/8-GiB/40-GiB development VM, not a claimed VMM Pod cgroup.
The observed VMM is in `k3s.service`; its idle RSS sample is not a stress test or
a hard quota guarantee. Other resource shapes remain unsupported.

### Offline networking requires the bridge guard

The live negative control disproved NetworkPolicy-only isolation: a node-port
listener was reachable from the Pod, and the node could connect into the Pod.
The failed report remains referenced in the checked-in evidence.

`install-preview.sh` now installs a root-owned, VM-local administrator service,
`smolbox-preview-offline.service`. It maps each preview Pod UID through CRI to
its CNI namespace and physical bridge port, then atomically populates one owned
nftables bridge set. Early ingress and final egress hooks drop **all Ethernet
frames** on those selected ports. Other namespaces' ports and K3s's own rules
are untouched. This closes IPv4, IPv6, node-port, node-originated ingress and
ICMP exceptions instead of relying on IP-only deny rules. The hook selection
follows the [nftables bridge filtering model](https://wiki.nftables.org/wiki-nftables/index.php/Bridge_filtering).

The guard is bound to the original namespace/node UIDs. Observation failures
retain the previous drop set; stale evidence cannot authorize application
dispatch. A new Pod is only a trusted neutral keeper until its bridge mapping
is verified. Before staging inputs or executing application code, the future
NodeEvidence provider must require fresh state, matching Pod/sandbox/interface
identity, exact live drop rules, and no qualification permits.

Root-only qualification permits expire after 120 seconds and apply only to
explicitly marked canary Pods. The probe temporarily permits its canary to
establish working IPv4/IPv6 and inbound controls, removes the temporary network
allowance and permit, then verifies isolation with the same Pod. Runtime
application credentials have no access to this administrator mechanism.

The resulting live probes passed node/gateway/node-port, cluster API/DNS,
public-IP, metadata-address and IPv6 link-local rejection, plus inbound rejection.
Both bridge hooks recorded drops. Real WebSocket v5 exec remained usable over
the control path, preserving 4,352 raw stdout bytes, binary stderr, and exits
0 and 7. UID-preconditioned deletion collected the original KVM process and
returned machine/directory/share inventories to their baseline.

This is a **lab-only** infrastructure recipe. Its bridge mapping and observer
assumptions must not be exported as general distribution/CNI support.

### Node evidence contract and remaining Phase 6 gate

Capture the enrolled node UID/boot identity, namespace UID, original Pod UID,
all discoverable CRI sandbox attempts, verified VM-name/directory mapping,
original boot-process executable hash and PID birth, and fresh offline-guard
membership before application I/O. Persist the typed receipt under store guards.

Deletion must retain that authority, verify API absence under the original UID,
and positively observe original process termination plus scoped record/directory/
share absence. Polling/observation has one deadline and cannot issue machine
mutations. Mapping gaps, lost attempt history, observer gaps, stale guard state,
node reboot or unknown namespace identity fail closed and retain the reservation.
An empty list, disappearance of a Pod, or a successful SSH command alone is
insufficient. The Phase 0 smoke captures and checks this evidence for its own
single observed attempt. Phase 4 adds the reusable capture provider and a typed
physical-proof component below; managed proof persistence/release and recovery
remain Phase 6 gates.

## Validation so far

The manual Python suite passes 48 tests, including transaction history, node
inspection, fixed-helper framing, argv/env,
stdin EOF and validation rejection, plus existing smoke evidence
gates, WebSocket fragmentation/binary/terminal-status failures, edited/foreign
bridge-rule rejection, policy drift, and archive/rootfs integrity. All four shell
scripts pass syntax checks and ShellCheck. No CI workflow was changed.

The [lab guide](../kubernetes-lab.md) documents manual setup and commands.
New Elixir backend contracts and public-path tests remain required before any
backend completion claim.

## Phase 1 — Typed target and ownership boundary

`SmolBox.Kubernetes.Config` validates the enrolled cluster anchor, namespace,
node/boot and RuntimeClass identities, the pinned runtime/guard descriptor,
explicit HTTPS/CA/auth settings, OCI catalogs and the exact Phase 0 profile.
Configuration and normalization call no credential or node provider. Credential
and observer contexts are excluded from Inspect and durable binding generation;
token rotation or an API tunnel port change cannot silently change data domains.
Every enrolled incarnation/policy change does change the binding generation.

Creation assignments freeze the exact normalized version-1 Pod manifest, its
digest, a random nonce, approved source/profile, execution key and fingerprint.
The manifest carries opaque identifiers and a neutral keeper, not application
argv/env. Version-1 template validation must remain immutable when later schemas
are added. Receipts bind an original Pod UID and refine readiness once to its
container/image identity and typed KVM/bridge observation. Refreshing observation
time cannot replace a container, process birth, observer epoch or Pod UID.
Ownership observations can record unavailable isolation or incomplete history;
`Observation.dispatchable?/4` separately requires matching, complete, fresh,
isolated evidence before application I/O. An isolation failure must not prevent
deleting a known owned VM, while incomplete history still prevents capacity release.

`Machine` comparisons and execution observation validation now have an explicit
Kubernetes identity branch. A cleanup-proof DTO requires the same capture and
observer authority, original process termination, API absence and scoped record,
directory and share absence. A cleanup proof cannot predate the latest saved
live observation. These are validators for evidence supplied by the
future provider; they do not create or attest live evidence themselves.

At the Phase 1 close, the shared record validator deliberately rejected Kubernetes
persisted records until Phase 2 added their selective envelope and store contract.
Tests verified that encoding them, or injecting them into legacy HTTP/Embedded
envelopes, failed. Enrollment and target eligibility were disabled; the adapter still
advertises no operations. A runtime version string cannot
enable HTTP capabilities on a Kubernetes target. Existing stored records and
HTTP/Embedded behavior retain their contracts.

Twelve focused cases cover invalid enrollment/TLS/catalog/profile data, binding
incarnation changes, secret redaction, canonical intent and mutation, Pod/
container/PID reuse, stale or incomplete node evidence, missing cleanup facts,
legacy-envelope rejection and the public runtime startup gate. The default
HTTP/Embedded/unit/contract suite passed 2,190 tests, with 42 opt-in tests excluded.
Formatting, compilation with warnings as errors, zero dependency cycles, strict
Credo, zero-clone ExDNA, Dialyzer and strict-assumption Credence all passed.
No CI workflow or live Kubernetes infrastructure changed in this phase.

Phase 2 must persist the initial Pod UID receipt before readiness and application
I/O. Keep `created_machine` immutable: assign its final running observation only
after the initial receipt has been refined and saved, instead of replacing a
previously saved pending machine observation. This preserves the existing
execution evidence transition invariant while adding the early Kubernetes UID
receipt in its own field.

## Phase 2 store and admission gate

The gate passed on November 13, 2026. Kubernetes disposable intent uses selective
codec **v54**. Existing envelopes omit the three new nil defaults exactly and
reject Kubernetes authority, including queued zero-retention intent. Golden
HTTP and Embedded payloads captured from commit `8eb2dcb6` retain their fields,
envelopes and fingerprints. The byte test applies the original ETF writer to
those untouched legacy payloads in the same VM: ETF map ordering depends on the
BEAM atom table and was never canonical across separate VM runs.

Atomic reservation saves the typed assignment, Pod name, resource charge and
`backend_create_state: :pending`. Before a future POST, orchestration must save
`:dispatched`; this state cannot reset. The initial original-UID receipt can then
be saved and refined to ready, without replacing a Pod/container, sandbox,
process birth or observer epoch. `created_machine` remains immutable and is
saved only with the final ready observation. Cleanup proof binds to the exact
latest saved receipt. API absence without physical evidence cannot complete
cleanup or release capacity. The separate `:not_dispatched` cleanup marker is
valid only while create is durably pending with no receipt; it cannot resolve
an ambiguous POST. Post-POST preparation failures without sufficient node
history remain charged until Phase 6 supplies a valid cleanup path.

Both Memory and the reference PostgreSQL adapter advertise `kubernetes_backend: 1` after the shared transaction contract. Recovery retains released tombstones.
Namespace or node aliases within an enrolled cluster anchor cannot create a
second capacity pool under another target ID. PostgreSQL stores full Kubernetes
enrollment in authenticated encryption tied to partition and target ID, validates
kind/generation projections, and authenticates complete record scans before
using their worker projections. A missing ledger does not erase assigned domain
authority. Migration `20261113000000_kubernetes_bindings` adds nullable enrollment
payload storage without rewriting existing execution payloads; apply it with
controllers stopped and upgrade all readers before enrollment. Rollback refuses
to discard Kubernetes bindings.

Public submit accepts only an exactly approved digest-pinned OCI source, fixed
offline profile, foreground command with no stdin/user override, and explicit
`retention_ms: 0`, on a Kubernetes-capable store. Positive retention is not
silently shortened. HTTP/Embedded disposable remote-source policy and positive
retention behavior remain unchanged; retained command attachment rejects zero
retention. Repeated submission retains the first absolute deadline and rejects
changed intent. Runtime startup validates the marker and enrolls the typed
domain separately from Embedded recovery. The Kubernetes adapter still
advertises **no operations**: accepted intent cannot create a Pod at this gate.

Validation: 2,202 main-project tests passed (42 opt-in excluded); 308 PostgreSQL
example tests passed (29 opt-in excluded). Focused checks cover atomic capacity,
stale claims/versions, immutable UID/container authority, cleanup proof mismatch,
double release, old-envelope injection, source/retention gates, transaction
rollback, tampered enrollment, a lost ledger and displaced worker projection.
Format, warnings-as-errors compilation, zero dependency cycles, strict Credo,
zero-clone ExDNA, strict-assumption Credence and Dialyzer passed. The PostgreSQL
run used an isolated local Unix-socket database; no live VM or CI change was
needed in this phase. [Machine-readable report](../evidence/kubernetes-backend-phase2-2026-11-13.json).


## Phase 3 bounded object API gate

The gate passed on November 13 (Denver; November 14 UTC), 2026. Object operations
use the existing Mint dependency directly, with verified CA/hostname, HTTP/1.1,
a 16-KiB response-header cap, bounded JSON and a single monotonic deadline.
Request/response byte allowances accumulate across enrollment reads, polling and
inventory pages. Token-file reads and host credential callbacks run inside the
same deadline in an isolated request process. Caller death terminates that
process and its socket. There are no redirects, automatic retries, decompression,
kubeconfig plugins or arbitrary credential commands.

Enrollment checks the pinned server version, kube-system anchor UID, workload
namespace UID, node UID/boot/runtime/readiness, RuntimeClass UID/handler/overhead/
selectors and administrator-owned offline policy identity/spec. The policy digest
includes the policy UID. Source approval still comes from the exact host catalog;
Kubernetes declarations do not attest effective networking or installed binaries.
The qualified node-evidence provider remains a separate Phase 6 gate.

The assigned Backend port accepts only the saved creation intent or exact Pod
name. Create returns the original UID receipt before readiness; known admission
mutation retains a receipt for cleanup but fails before application IO. Recovery
uses a one-name GET with complete immutable intent comparison and never sends a
second POST. Readiness requires the original UID, pinned manifest imageID,
qualified effective defaults, one workload container, zero restarts and, once captured, the saved container
incarnation. The pinned CRI's `status.image` is a config/display digest;
it is not used as source authority. The Pod spec image and `status.imageID` must
retain the approved platform-manifest reference.

API deletion checks the original namespace/cluster authority and uses an atomic
UID precondition and bounded grace. It reports only `:api_absent`, never physical
cleanup. A changed node readiness/policy cannot prevent UID-bound cleanup of an
owned Pod in the original namespace. Finalizers, UID replacements, denied access,
lost responses and incomplete inventory remain errors, with no release of
capacity. Inventory has resourceVersion/continuation validation, per-page and
total bounds, and rejects repeated tokens or duplicate identities. Unassigned
health and all application operations remain unsupported, so the managed runtime
still cannot start Kubernetes work automatically.

The live check used the real preview RuntimeClass and pinned Python image through
restricted service-account credentials, including the Backend assigned port.
Six forbidden capabilities were denied: create/read Secrets, update/list Nodes,
patch NetworkPolicies and create RuntimeClasses. The example RBAC is in
`scripts/kubernetes/runtime-rbac.yaml`. Original KVM PID births, runtime executable
hash, sandbox/SQLite record, disk directory and host share were observed before
delete. After UID deletion, those original processes/paths/records and all pinned
runtime KVM holders were absent. These manual facts are **not** a production
NodeEvidence proof and did not complete a store reservation or qualify app IO.
The physical host and existing workers were unchanged.

The live check also exposed two gaps in the earlier same-process store gate.
`Shape.digest/1` had not descended into tuple-wrapped maps, making binding and
intent hashes depend on the BEAM atom-table order. Recursive tagged tuple
canonicalization fixes this. The safe decoder now explicitly loads the authority
validation module defining the create-dispatch atoms. A regression writes queued/
dispatched/created/ready authority and reads it in a fresh BEAM with a different
atom initialization order. Old experimental hashes fail closed; no automatic
migration/adoption was introduced. The first affected lab Pod was deleted under
its saved original UID and physically collected before fresh intent was tested.
Existing HTTP/Embedded encodings and fingerprints retain their contracts.

Validation: 2,222 main-project tests passed (42 opt-in excluded), followed by
46 focused Kubernetes cases including final inventory/UID-race hardening.
The PostgreSQL backend/Kubernetes authority suite passed 25 cases after the hash
fix. Format, warnings-as-errors compilation, zero dependency cycles, strict Credo,
zero-clone ExDNA, strict-assumption Credence and Dialyzer passed. All live checks
remain manual; no CI workflow changed. [Exact report](../evidence/kubernetes-backend-phase3-2026-11-13.json).


## Phase 4 — Initial command transport checkpoint

The Elixir v5 transport and fixed Python helper are implemented. An assigned
backend accepts only the saved foreground command and ready receipt. Application
argv/env travel in bounded length-framed stdin; only a constant helper program
appears in the exec URL. Application stdin is `/dev/null`. A helper acknowledgement
separates validation diagnostics from application output. The producer stays open
through completion, avoiding the pinned runtime's stdin CloseIO/FIFO race.
[Protocol and error semantics](kubernetes-backend-exec-protocol.md).

The transport reuses verified Mint TLS, offers only v5, disables extensions and
has no fallback/replay. A shared bounded frame parser preserves existing terminal
behavior. Stream/status decoding preserves arbitrary binary, real exits and
bounded partial results; missing or conflicting status cannot manufacture success.
Owner loss, deadline, output limits and synchronous callback stalls close the
socket. An explicit 401/403 remains a definitive authorization rejection.
The helper is packaged and embedded at compile time; a fresh production consumer
with an independent build path qualifies the package boundary.

The live **component** probe used the restricted service account, real SmolVM
and the exact Phase 0 Python image. It passed silent exit 0, exit 7, exact argv/env,
application stdin EOF, 768 arbitrary stdout bytes and binary stderr. An induced
callback stall lost observation before exit; a later independent read found the
counter incremented once. The uncertain application command was never replayed.
UID/container checks surrounded each operation. UID-bound deletion then positively
collected the original PID birth, VM directory, share and SQLite record; no pinned
runtime KVM holder or preview Pod remained. These facts did not release capacity.
The idle disposable lab VM was stopped after collection.

Kubernetes 1.35's default authorization gate also requires `create` on `pods/exec`
for a GET WebSocket upgrade. The initial GET-only role returned 403 before helper
dispatch. The namespace role now grants get/create on that subresource; no broader
node, Secret or policy mutation permission was added. See the
[upstream change](https://github.com/kubernetes/kubernetes/blob/v1.35.0/CHANGELOG/CHANGELOG-1.35.md).
The first rejected probe was definitive; it was not an uncertain command replay.

**At that checkpoint, Phase 4 was not complete.** Its live component probe exercised the fixed-helper/
WebSocket layer directly, not the guarded assigned exec path. The reusable real
NodeEvidence provider was still absent; unit fixtures did not qualify it. Assigned
exec required fresh isolation, complete history and the exact saved incarnation
before and after application I/O. That gate remained closed until the prerequisite
and guarded live test described below passed. A one-time CRI/SQLite/process
snapshot could not establish complete sandbox-attempt history. Cleanup/recovery
and public qualification remain separate gates.

[Transport component evidence](../evidence/kubernetes-backend-phase4-transport-2026-11-13.json).
No CI workflow changed; all lab qualification remains manual.


Transport checkpoint validation: 2,240 main-project checks passed (42 opt-in
excluded) with eight concurrent cases. The first 32-case run expired a 300-ms
client-test budget before TLS dispatch while other tools were active; its
expected after-dispatch evidence therefore did not apply. The isolated focused
check passed, followed by the complete eight-case run. After final close/status
hardening, all 27 focused exec/remote-command/terminal-transport cases passed.
The 26 Python cases, fresh production package consumer, formatting, warnings-as-
errors compilation, zero dependency cycles, strict Credo, zero-clone ExDNA,
strict-assumption Credence and Dialyzer also passed.


## Phase 4 — Guarded adapter exec gate

The gate passed on November 13 (Denver; November 14 UTC), 2026. The prerequisite
[lab node-evidence provider](kubernetes-node-evidence.md) now uses administrator-
installed SQLite transaction triggers to retain every runtime VM-record change,
a separately fsynced ownership/prefix ledger, read-only node inspection and a
fixed bounded SSH protocol. Polling or the best-effort upstream usage journal
cannot silently stand in for this continuity. Exact runtime/source identities,
PID births, KVM descriptors, guard state and original UID/container authority are
checked before and after application I/O. Codecs/receipts remain unchanged.

The first neutral keeper revealed the runtime's empty per-VM readiness marker
in shared rootfs. No shipped file had changed. The verifier now recognizes only
an exact journal-bound, regular, single-link, zero-byte marker; all shipped
assets still match the archive manifest. Before any ready receipt or app dispatch,
the correction preserved all journal events and rotated the inspector epoch.
The first preparation was failed and collected under its original UID; its
absolute deadline was not reset and its application was never dispatched.

Fresh execution intents then passed through the **assigned Backend exec_stream
port**, with real saved ready receipts and the real host provider rather than
unit evidence or a transport-only bypass. Silent exit 0, exit 7, arbitrary binary
stdout/stderr, exact argv/env and application stdin EOF passed. An induced callback
stall closed observation with `:dispatch_uncertain` and no fabricated exit.
A separate administrator file read confirmed the counter incremented once; the
original command was not resubmitted. Final cases repeated these checks with
combined API/node/application byte-budget accounting. Each case used fresh BEAM
processes between create, execute and delete, retaining the saved authority.
This is not managed-controller recovery qualification.

UID-bound deletion was followed by real typed physical-proof validation. A
controlled empty share left at the original sandbox path caused proof refusal
and remained untouched by the provider. Only the administrator's identified
fixture inode was removed; a subsequent fresh proof passed. No component driver
released store capacity. All probe Pods and original VM processes, records,
directories and shares were collected; the enrolled lab remains running, idle,
for the next implementation phase.

Validation: 2,246 main-project checks passed with 42 opt-in excluded, followed by
15 focused node-provider/exec cases after the budget-helper dependency refactor.
The 48 manual Python cases, fresh production package consumer with an independent
build path, formatting, warnings-as-errors compilation, zero dependency cycles,
strict Credo, zero-clone ExDNA, strict-assumption Credence and Dialyzer passed.
The package report's source hashes match the current packaged files. New unit
cases reject changed observer epochs/PID births before exec, invalid/truncated
node frames, SSH argument injection, lost owners, history corruption and leaks.
No CI workflow or physical-host worker baseline changed.

[Guarded exec and node-capture evidence](../evidence/kubernetes-backend-phase4-2026-11-13.json).
At this checkpoint Phase 5 files, Phase 6 managed cleanup/recovery and Phase 7
public qualification remained required. Runtime health/admission stayed disabled.


## Phase 5 — Bounded files through the shared runtime

The assigned file gate passed on November 13 (Denver; November 14 UTC), 2026.
[File protocol](kubernetes-file-protocol.md) describes the fixed sealed loader,
length framing, workspace directory descriptors, atomic upload, changing-file
checks and strict reply validation. Application paths and payloads remain outside
the exec URL. Both helper sources ship in the package and compile on the Mac;
the loader's Linux memfd execution was qualified in the real MicroVM.

The real assigned backend, fresh node guards and shared `Runtime.Files` staged
and read back empty, 4,352-byte and 1-MiB binary inputs, including a quoted Unicode
path. A single foreground command checked digests, reversed the bytes, emitted
binary stdout/stderr and exited 7. Shared collection published the exact three
artifacts and preserved that exit. The application also verified that it did not
inherit the sealed helper descriptor. A deliberately wrong upload checksum was
rejected by the real utility (exit 126) and left the prior input unchanged.

A second execution produced a symlink instead of its declared output. Collection
failed with utility exit 126, published no artifact and preserved the application's
exit 7. Its CRI sandbox outlived the manual driver's 30-second observation deadline;
that failed check remains recorded. A subsequent read-only observation of the
original UID confirmed CRI absence and obtained fresh typed physical cleanup
proof. The command was never replayed. The driver's ephemeral store had exited,
so this case does not claim reservation release or controller-recovery success.
The successful file case did persist proof and perform guarded manual Memory
store release, observing zero slots. Neither case qualifies managed cleanup.

Unit coverage includes binary boundaries/backpressure, duplicate/malformed reply
headers, missing acknowledgements/status, helper exit evidence, identity/history
changes before transfer, manifest/path limits, corrupt read-back/publication and
slow ArtifactStore callbacks. Python cases also cover interrupted uploads, digest
mismatch, atomic replacement, temporary cleanup, symlinks, hard links, FIFO/directory
rejection and files changing during download.

[Exact Phase 5 evidence](../evidence/kubernetes-backend-phase5-2026-11-13.json).
Phase 6 managed cleanup/recovery and Phase 7 public qualification remain pending;
public Kubernetes health/admission stays disabled. All cluster checks remain
manual and no CI workflow changed.

Final validation: 2,259 main-project checks passed (42 opt-in excluded), 22 focused
exec/file/runtime-file cases passed, and 56 manual Python cases passed. A repeated
boundary check caught TLS coalescing valid frames into a read larger than the
wire parser's feed cap. The adapter now feeds bounded chunks after accounting
the full read; the final suite and a fresh live file campaign passed after this
fix. Formatting, warnings-as-errors builds, strict Credo, zero-clone ExDNA,
strict-assumption Credence, Dialyzer and zero dependency cycles passed. A fresh
production package consumer on an independent build path included both helper
assets; all packaged library/asset hashes matched the checkpoint. The archive
precedes this final evidence/report text, so it is not a hash of the later docs.


## Phase 6 — Historical component checkpoints

These paragraphs preserve earlier checkpoints in order. The managed-authority
and public-qualification sections below describe the current version-3 preview.

The managed preparation path now saves create dispatch intent before POST, saves
its original UID before readiness, and captures/persists the ready incarnation
before staging. The dedicated Kubernetes cleanup branch runs before generic
machine-not-found/stop handling. Pending intents can complete with explicit
not-dispatched evidence. Lost responses reconcile the exact saved Pod intent
without a second POST; missing original mapping remains unresolved. A known UID
can still be deleted after readiness rejection, without inventing a physical
proof or releasing capacity.

The cleanup path saves a fresh matching typed proof before guarded release;
failed proofs retain the reservation and original result. Once mutation attempts
or their absolute deadline are exhausted it permits only a separately bounded
read-only proof observation, preserving the original deadline. Unit cases cover
cancellation, missing original objects, foreign replacements, mutated Pod
responses, old proofs, original nonzero exits, and failures before/after proof
persistence and before release. The focused lifecycle/file-runtime set currently
passes 23 checks. A different controller is explicitly refused ownership takeover
until positive quiescence is implemented. This is implementation progress, **not the Phase 6 exit gate**.

Operational health/admission remains disabled. Remaining prerequisites include
complete authenticated startup scans and tombstones, positive old-controller
quiescence before ownership takeover, CRI sandbox absence integrated into the
pinned built-in node proof, safe reconciliation of in-flight preparation, and
live cancellation/controller-restart qualification with durable storage. The first history-preserving verifier maintenance is now qualified: version 2
adds original CRI sandbox absence, while retaining all journal events and owners.
See [cleanup authority and remaining gates](kubernetes-cleanup-authority.md).
This version-2 component checkpoint does not yet establish kubelet/controller
quiescence or enable public admission.


Phase 6 component evidence now includes real shared preparation, binary execution
and ArtifactStore collection, then shared Runtime.Cleanup saving a CRI-bound
version-2 proof before guarded release. Two capture retries and fourteen cleanup
rejections stayed within their bounded observation paths; the command was not
replayed and capacity stayed charged until proof. The first failed preparation
and the lifecycle feasibility probe were collected under their original UIDs;
neither lost ephemeral store is reported as recovered release authority. The
reference PostgreSQL contract passed 11 checks, including historical-proof
non-release. Full startup/controller/kubelet quiescence remains pending.


[Exact Phase 6 component checkpoint](../evidence/kubernetes-backend-phase6-components-2026-11-13.json):
2,280 main-project checks passed (42 opt-in excluded), 63 manual Python cases,
11 reference PostgreSQL contract checks, fresh independent production package
consumer, formatting, warnings-as-errors compilation, strict Credo, zero-clone
ExDNA, strict-assumption Credence, Dialyzer and zero dependency cycles passed.
Packaged product source/asset hashes match this checkpoint; the archive precedes
the final report text. Phase 6 remains in progress, with public admission closed.


## Phase 6 — Managed authority gate

The version-3 inspector captures and persists the original guaranteed-QoS Pod
cgroup while the original KVM process runs. Cleanup requires its absence with
unchanged node boot/cgroup mount/K3s/containerd births, plus original API/CRI,
process, SDK record, VM-directory and share absence over the complete transaction
journal. Historical version-1/2 proof data remains readable but cannot release.
The administrator upgrade preserved 65 events and 13 sandbox owner mappings,
rotated the verifier epoch, and retained database inode/audit authority.

The fixed same-host controller helper preserves complete bounded PID/birth/boot
owner history in private local metadata. It refuses a paused original process,
lease-only takeover and reset-ledger adoption of existing data. Startup freezes
all work until an authenticated scan of every assignment and tombstone succeeds,
original owners/bindings/incarnations match, and final API/node inventory agrees.
Dispatched work becomes unknown without exec. Ready work waits for complete scan
and fresh observation. Inspection is bounded, read-only and redacted.

A real durable public command reached running, then the original BEAM was paused.
A second controller was refused without changing its ledger. After positive
original-process death, a new controller recovered the same PostgreSQL execution
and Pod UID, kept the outcome unknown, collected version-3 cleanup proof and
released to zero slots. Public cancellation also preserved unknown outcome until
positive original-UID cleanup. Memory and PostgreSQL binary runs preserved exit 7
and exact artifacts. These runs use real SmolVM, rather than unit proof fixtures.

[Phase 6 authority evidence](../evidence/kubernetes-backend-phase6-2026-11-13.json)
records exact sources, component proof, administrator maintenance, Mac OS guard
control, durable restart/cancellation and validation. The older component report
remains historical and is not rewritten to claim stronger proof authority.
All cluster/Python checks remain manual and CI workflows are unchanged.

Phase 6 final verification passed 2,297 main checks (42 opt-in excluded), 310
reference PostgreSQL checks (29 opt-in excluded), 77 manual Python checks and
20 focused fault regressions. Formatting, strict Credo, zero-clone ExDNA,
strict-assumption Credence, Dialyzer, zero dependency cycles and a fresh independent
production package consumer passed. All packaged library/asset hashes match this
checkpoint. Teardown ordering and overly tight TLS test deadlines were corrected;
failed validation runs are retained in the private campaign logs.


## Phase 7 — Public preview qualification

The manual public API campaign passed Memory and encrypted PostgreSQL binary
input/read-back/output publication with exit 7, a silent exit 0 through the
checked-in settings example, cancellation, output overflow, lost create response,
lost exec status and durable controller restart. Unknown results stayed unknown;
all completed physical cleanup before releasing their original reservations.
Loopback fault traces recorded one POST per induced case, no exec after lost
create or changed-container observation, and exactly one exec for lost status.
The changed-container fault modifies an API observation after initial capture;
it does not claim to physically replace the MicroVM.

A real foreign Pending Pod remained unscheduled and untouched by the runtime.
The complete startup scan rejected foreign inventory; public audit classified it
as foreign. The administrator removed only its saved UID. Persistent draining
blocked new reservation, cancellation before dispatch sent no application work,
and resume used the expected control revision. Stale namespace/node/boot/class/
policy approvals were rejected against the actual API without destroying enrolled
objects. A valid unapproved source was rejected by catalog admission.

The foreign control exposed K3s PodList items omitting TypeMeta. The adapter now
fills only absent `kind`/`apiVersion` from the typed list and rejects explicit
wrong/null types. The peer's ordinary list responses match K3s, and a focused
regression protects nonempty recovery/inspection.

Final authenticated PostgreSQL enumeration found all seven assigned executions
with matching version-3 proof, cleanup complete and no reservation. Usage was
zero slots/CPU/memory/disk; the node reported idle with complete unchanged history.
No fault proxy or managed VM remained. The outer VM retains its four-hour cap.
The physical host and existing worker configuration were not mutated.

[Exact public qualification evidence](../evidence/kubernetes-backend-phase7-2026-11-13.json)
records cases, identities, trace counts, source/asset hashes, previous failures
and their corrections. The final main suite passed 2,298 checks (42 opt-in
excluded); the reference PostgreSQL suite passed 310 (29 opt-in excluded),
with all 12 current Kubernetes contracts passing. All 77 Python checks remain
manual. Full first-preview requirements and test boundaries are mapped in the
[release audit](kubernetes-backend-release-audit.md).

## Review follow-up — queued admission and ready recovery

An occupied single-node slot now reports temporary admission exhaustion, keeping
valid accepted work queued until capacity is released. Operational health errors
retain their original classification; unsupported policy remains a permanent
admission rejection.

Startup recovery now persists cancellation or preparation expiry as a terminal
state before entering the existing cleanup path. It does not require a missing
original Pod to become ready again. Final startup verification re-reads ready
records so cancellation between scan pages is also honored. Original-incarnation
version-3 proof is still required before reservation release; unavailable proof
keeps the worker frozen and capacity charged. Recovery never dispatches this work.

Six new regressions failed before the fixes and pass afterward, including queued
execution after slot release, operational health failures, cancelled/expired ready
records, unavailable proof and cancellation between pages. Validation passed
2,304 main checks (42 opt-in excluded), 52 focused checks and all 12 reference
PostgreSQL Kubernetes contracts, plus formatting, strict Credo, zero-clone ExDNA,
strict-assumption Credence and Dialyzer. The test fixture now isolates its directory
before deletion to prevent late OS-helper writes racing teardown; the lost-upload
test allows TLS setup time while retaining its uncertainty/no-replay assertions.
The original live reports remain historical; this follow-up uses local API/store
fixtures and changes no node verifier or CI workflow.

## Review follow-up — command output and infrastructure budgets

Kubernetes command observation now retains the assigned reference's configured
aggregate response budget instead of shrinking it to the profile's output cap.
API reads, controller authorization and node proofs share that bounded allowance;
the command parser still independently enforces the combined decoded stdout/stderr
cap. Existing tighter reference bounds remain effective, and HTTP/Embedded retain
their previous output-derived transport bounds.

Four public-runtime regressions failed before the fix and pass afterward. They
cover silent commands with 1-byte and 4-KiB output caps, exact combined binary
output at 4 KiB and overflow by one stderr byte. The API fixture includes 4 KiB
of Node metadata, and node capture rejects an observation that cannot fit its
granted response budget. Every case verifies one create, one application exec,
positive cleanup and zero reserved slots. A direct backend check also verifies
that an explicit small aggregate response budget still rejects control traffic
before application exec. These are local fixtures; no new live qualification or
CI workflow change is claimed.

Validation passed all 2,309 main checks (42 opt-in excluded), 64 focused checks
and both original review reproductions using the captured K3s Node response.
Formatting, strict Credo, zero-clone ExDNA, strict-assumption Credence and
Dialyzer passed. The initial full run hit an existing 300-ms TLS-deadline test
while static checks were also running; the focused test and full rerun with
lower concurrency passed without changing that test.

## Review follow-up — recovery collection and worker leases

The coordinator now runs one supervised recovery task per Kubernetes target,
outside the lease-bounded health probe. Probes continue renewing the worker lease
and return the latest completed observation. Recovery observations have a separate
cache so a scan captured before a task result cannot overwrite its cursor or
completion. Startup admission remains fenced until the full existing reconciliation
and activation path finishes. The task supervisor reserves an additional slot for
each Kubernetes target, preserving normal execution, maintenance and scan capacity.

The original stage deadlines, store claim checks, host controller authority and
proof-bound cleanup rules remain in force. Failed recovery tasks clear their
cached observation and retry under the closed fence. A failed worker-lease renewal
causes observed collection IO to stop when ownership expires. Recording successful
publication or releasing capacity still requires valid store claims.

Three regressions cover publication held beyond the smoke tool's five-second
lease, death of the recovery task, and failed lease renewal. They verify continued
renewal, queued admission while fenced, safe recovery retries, preservation of the
original exit/deadline, binary publication and version-3 cleanup before release.
The slow-publication test failed before the fix because the health probe killed
its publisher. These checks use local fixtures and leave CI workflows unchanged.

Validation passed all 2,312 main checks (42 opt-in excluded), all 24 recovery
checks and both original review cases. The original six-second publication now
finishes in one attempt with either a five-second or a thirty-second lease.
Formatting, strict Credo, zero-clone ExDNA, strict-assumption Credence, Dialyzer
and the zero-cycle dependency check passed. No new live-node qualification is
claimed.

## CI follow-up — portable fixtures and example compatibility

Linux reproduced eight failures in the recovery/file fixture subset. Recovery
polling now allows fifteen seconds for the full TLS/controller/exec/cleanup chain,
without changing any production stage deadline or backend operation budget. The
artifact callback test advances its own clock only after publication begins, so
it tests callback expiry independently of TLS setup. Its longer fixture lease
keeps worker ownership valid while that test clock advances.

The shared Kubernetes binding helper compiles its functions only when the SDK
provides Kubernetes binding types, preserving the community example's released
SDK dependency. The packaged guide links to the repository's settings example
instead of traversing outside the generated documentation directory.

The same isolated Linux subset now passes all 28 checks. The community example
passes compilation, strict Credo, zero-clone ExDNA and Dialyzer, and generated
documentation passes the local-link check across all 162 pages. CI workflows
remain unchanged; live Kubernetes/Python campaigns remain manual.
