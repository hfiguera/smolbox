# Kubernetes first-preview release gate audit

Qualified November 13, 2026 (November 14 UTC), on the single enrolled Linux/K3s
lab with an Apple Silicon/macOS controller. This closes Phases 0–7 of the
[implementation plan](kubernetes-backend-implementation-plan.md), scoped by the
[design](kubernetes-backend.md). Full HTTP/Embedded domain parity remains the
explicit long-term goal in the [parity matrix](kubernetes-backend-parity.md).

| Gate | Evidence and outcome |
| --- | --- |
| 0: actual runtime, sizing, effective offline isolation | [Phase 0](../evidence/kubernetes-backend-phase0-2026-11-13.json): pinned archive/shim/rootfs/kernel, real KVM, fixed 2-vCPU/1-GiB guest and 20/10-GiB templates; failed NetworkPolicy-only control retained; qualified bridge guard closes ingress/egress. No VMM cgroup quota claim. |
| 1: explicit immutable target/intent/incarnation | Constructors and authority regressions; approved digest source/profile, canonical binding, frozen nonce/intent, original UID/container/VM birth receipts. No credential contexts in persisted authority. |
| 2: atomic persistence and reservation authority | [Phase 2](../evidence/kubernetes-backend-phase2-2026-11-13.json): selective v54, unchanged legacy formats/fingerprints, atomic reserve/receipt/proof release, authenticated enrollment/corpus, Memory and PostgreSQL contracts. |
| 3: scoped object lifecycle and restricted credentials | [Phase 3](../evidence/kubernetes-backend-phase3-2026-11-13.json): bounded verified TLS, single POST, exact intent reconciliation, readiness and UID-precondition deletion; restricted RBAC negative controls. |
| 4: bounded foreground execution and no replay | [Phase 4](../evidence/kubernetes-backend-phase4-2026-11-13.json) and public cases below: v5 binary channels, actual exits 0/7, sealed length-framed helper, EOF limitation documented, caller/status loss stays uncertain without another exec. |
| 5: files and shared artifact publication | [Phase 5](../evidence/kubernetes-backend-phase5-2026-11-13.json) and public binary runs: empty/4,352-byte/1-MiB component boundaries, exact hashes/read-back, corruption preserves input, unsafe output is not published, actual exit survives collection failure. |
| 6: cleanup, controller authority and restart | [Phase 6](../evidence/kubernetes-backend-phase6-2026-11-13.json): transaction-backed original sandbox history; version-3 API/CRI/VM/path plus kubelet lifecycle proof; unchanged daemon births; paused-controller refusal; positive original BEAM death; complete authenticated startup scans; no uncertain command replay; proof saved before guarded release. |
| 7: public API, faults and compatibility | [Phase 7](../evidence/kubernetes-backend-phase7-2026-11-13.json): Memory/PostgreSQL public commands/files, checked-in example, silent/nonzero/binary, cancellation, overflow, lost create/status, durable restart, foreign inventory protection, draining and identity controls; final complete durable corpus has seven version-3 proofs and zero reservations. |

The live foreign control exposed valid PodList items omitting `kind` and
`apiVersion`. The adapter now normalizes only missing TypeMeta, rejects explicit
wrong/null types, and tests use the actual list shape. Nonempty startup and
inspection passed against the real API after this correction.

The final main suite passed 2,298 checks, excluding 42 explicit opt-in cases.
The reference PostgreSQL suite passed 310 checks, excluding 29 opt-in cases;
all 12 current Kubernetes store contracts passed. Manual Python coverage passed
77 checks. The package consumer builds from an independent production path;
docs compile with warnings as errors. The evidence records formatting, static
analysis, source hashes, package identity and retained failed observations.
No new CI job or workflow modification is part of this preview. Ordinary unit
fixtures require no cluster/SSH; Python and live lab campaigns remain manual.

## Boundaries of this qualification

The changed-container control injects a conflicting API observation through a
verified loopback TLS proxy after original capture. It does not physically replace
the MicroVM. Namespace/node/boot/RuntimeClass controls check stale approvals
against real API objects; they do not destroy/recreate enrolled infrastructure.
Deterministic tests separately exercise replacement identities, PID reuse, epoch
changes, incomplete history, unavailable proof, leaked paths, old proof replay,
store failures and corrupt scans. In every incomplete-proof case, capacity stays
charged. These distinctions are explicit in the case evidence.

Kubelet lifecycle authority is an inference from the pinned source callers plus
live original-cgroup capture/absence, under exclusive namespace principals,
no original UID reuse, unchanged node boot/cgroup mount and unchanged daemon
births. This is the fixed lab mechanism. It is not production fencing or automatic
node-failure recovery. Node/daemon restart, mapping loss and corrupt metadata fail
closed and require administrator investigation.

The preview requires one controller host, one stable store partition and preserved
private controller metadata/keys. It supports only the approved Python OCI image,
fixed offline shape and explicit zero retention. Retained machines, broader
sources, credentials, networking/ports, volumes, workloads, terminals, checkpoints,
exports, branches, measurements and multi-node/production operation remain later
milestones. The [user guide](../kubernetes-backend.md) describes setup, manual smoke,
TLS/token rotation, inspection and unresolved cleanup.
