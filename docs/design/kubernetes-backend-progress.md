# Kubernetes backend progress

Status: implementation in progress, November 13, 2026. Follow
[the design](kubernetes-backend.md) and
[implementation plan](kubernetes-backend-implementation-plan.md).
The goal remains the complete first release, Phases 0–7, with HTTP/Embedded
parity tracked in [the parity matrix](kubernetes-backend-parity.md).

## Phase status

| Phase | Status | Evidence / remaining work |
| --- | --- | --- |
| 0 — Runtime qualification | Runtime gate passed in the dedicated lab | [Exact live report](../evidence/kubernetes-backend-phase0-2026-11-13.json); recipe and constraints below |
| 1 — Target and authority types | Type/validation gate passed | Offline constructors, immutable Pod intent, receipts, node observations, cleanup proofs and target normalization |
| 2 — Store/codec/OCI admission | Store gate passed | Selective v54, atomic allocation, UID receipt transitions, proof-bound release, authenticated PostgreSQL enrollment, gated OCI submission; operational dispatch disabled |
| 3 — Object lifecycle | Object API gate passed | Bounded TLS/token client, pinned object enrollment, assigned backend create/observe/readiness/UID-delete and restricted live RBAC; application IO and capacity release disabled |
| 4 — Exec | Pending | Elixir WebSocket client and application helper |
| 5 — Files | Pending | Qualified helper staging/collection |
| 6 — Cleanup/recovery | Pending | NodeEvidence provider, positive cleanup proofs and restart reconciliation |
| 7 — Public qualification | Pending | Public SmolBox smoke, compatibility evidence and user documentation |

Kubernetes authority types and target normalization are implemented; the backend
is not operational or enabled yet. Phase 0 demonstrates the upstream runtime and
resolves its network recipe. The library still needs store, transport, recovery
and public-path qualification before any execution can be admitted.

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

### Node evidence contract to implement in Phase 6

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
single observed attempt; the reusable provider and durable proof are still pending.

## Validation so far

The manual Python suite passes 21 tests, including existing smoke evidence
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
