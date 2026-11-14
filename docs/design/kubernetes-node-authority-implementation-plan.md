# Kubernetes node authority implementation plan

Status: Phases 0–3 implementation gates passed (installation fixtures and pre-enrollment access scope); Phases 4–5 pending, November 14, 2026.
Branch: `feature/kubernetes-node-authority`.
Implement the [single-node authority specification](kubernetes-node-authority.md).
This document creates no qualification claim or operational permission to change
the shared Linux host, reset enrollment or replace an active verifier.

Track phase evidence in [implementation progress](kubernetes-node-authority-progress.md).
The [frozen v1 contracts](kubernetes-node-authority-contract.md) define the exact
schema, canonical encoding, identity, privileges and proof obligations.

## Deliverable and sequencing

Deliver a standalone, administrator-installed evidence provider through the
existing `NodeEvidence` callbacks and disposable public runtime. Preserve the
current single-node scope and same-host controller guard. Distributed fencing,
multi-node operation, retained storage and other parity capabilities remain
separate branches in the [parity roadmap](kubernetes-backend-parity.md).

Use one branch for this coherent provider slice, with a commit after each passed
phase. If proof semantics, durable layouts or controller ownership need changing,
split a prerequisite design/implementation PR instead of expanding this branch.
Keep new operational selection disabled until the final qualification gate.

| Phase | Result | Dependencies |
| --- | --- | --- |
| 0 | Reviewed proof/identity/privilege and packaging contracts | Current preview source and evidence |
| 1 | Node verifier independent of lab provisioning | Phase 0 |
| 2 | Administrator installation and immutable enrollment | Phase 1 |
| 3 | Restricted framed endpoint and SDK provider | Protocol/identity decisions from 0; verifier from 1 |
| 4 | Public runtime, persistence and failure compatibility | Phases 2–3 |
| 5 | Manual live qualification and documented enablement | Every preceding gate |

## Phase 0 — Freeze the authority contract

Read the current inspector, history, lifecycle and offline-guard programs;
`NodeEvidence`, `Observation`, `Receipt`, `CleanupProof`, `Operation`, `FramedPort`;
the lab provider/controller; runtime recovery/cleanup; and both store adapters.
Compare the pinned source-basis reports with the actual qualified runtime.

Produce these implementation artifacts before generalizing the verifier:

1. An obligation table mapping each captured/proven fact to its source, durable
   witness, validation point and failure behavior. Distinguish API/CRI absence,
   VM process termination and kubelet lifecycle quiescence.
2. A configuration schema with exact field types, path/permission rules,
   read-only command allowlist, supported runtime layout, offline-guard inputs and
   explicitly fixed platform/version limits.
3. Protocol request/success/rejection fixtures for all three actions. Define
   canonical JSON, receipt/configuration digests and an authority-generation test
   vector. Keep history UUID and public observer generation distinct.
4. A privilege table for the administrator, SSH evidence principal, endpoint,
   Kubernetes observation credential and controller. Include effective SSH/sudo
   policy validation and attempts to request shell/forwarding/installation.
5. A compatibility decision proving that the existing opaque observer epoch
   carries the new generation without changing v54 record layouts. Enumerate
   cross-provider/downgrade rejection cases and old-reader expectations.

Potential files: `docs/design/kubernetes-node-authority.md`, a checked-in protocol
schema/fixtures directory, and a new node-authority source-basis report. Proposed
module/file names below can be refined together; wire constants and identity
encodings require explicit versioning once frozen.

Exit gate: every physical proof predicate and privileged operation has a named
owner and test. No reliance on API absence, polling-only history, Lease expiry,
or an unverified path/configuration digest can remain implicit. If v3 proof
semantics cannot be retained, stop and design its versioned successor first.

## Phase 1 — Extract a standalone verifier core

Proposed package: `priv/kubernetes/node_authority/v1/`, with focused modules for
configuration, history, physical observation, lifecycle and evidence projection.
Keep legacy lab program files and their pinned hashes intact while extracting.

1. Move node observations behind an immutable validated configuration. Remove
   hostname, namespace, lab-home and nested-VM assumptions from the new core.
   Requests never override this configuration.
2. Replace transitive imports from lab smoke/qualification utilities with the
   smallest self-contained reviewed implementations. Include every dependency
   in the package manifest; exclude the runtime CLI/SDK mutation paths.
3. Preserve transaction-trigger history, replay/preimage checks, exact original
   identity mappings, root-owned ledger continuity and all existing size bounds.
4. Preserve cgroup witness semantics, daemon/process birth checks and runtime
   asset validation. Parameterize only the approved paths/identities; retain
   source-version restrictions and the fixed VM/resource shape.
5. Separate evidence observation from administrator-owned offline-guard mutation.
   The new observer verifies the exact enrolled bridge rules and mapping. If
   extracting/configuring the guard is necessary, preserve its drop-first safety
   and scoped ownership and include its code/configuration in approvals.
6. Preserve atomic ledger writes, fsync/rename ordering, lock ordering, consistent
   before/after snapshots, interruption behavior and bounded child observations.

Tests: compare old/new projections from the same synthetic inventories, plus
incomplete mappings, missing journal events, rewritten prefixes, PID reuse,
reinserted sandboxes, leaked paths, replaced cgroups, daemon births, unknown
rootfs markers, changed guard rules and exhausted bounds. Inject interruption
around ledger publication; preserve enough state to reject ambiguous continuity.

Exit gate: identical qualified input produces semantically equivalent evidence;
every negative legacy case still rejects it. New code imports no lab provisioning
utility. No evidence/API operation can mutate a VM, Pod, guard or audit schema.

## Phase 2 — Package installation and enrollment

Proposed tooling: `scripts/kubernetes/node-authority/` for bundle construction,
administrator installation, read-only verification and manual qualification.
The application SDK never calls these installers.

1. Build a deterministic manifest/archive from the checked-in verifier bundle.
   Record program hashes, configuration schema and source-basis identities.
2. Validate absolute root-controlled paths, file ownership/modes, executable
   identities, node/runtime layout and read-only credentials before installation.
   Refuse symlink substitution and partial/different existing installations.
3. Install the fixed entrypoint and enrollment configuration. Generate an SSH
   principal/key policy and exact privilege-elevation example for administrator
   review; do not edit or restart the physical host's SSH/container runtime.
4. Under the documented transaction/lock ordering, require the complete positive
   empty baseline and install journal authority once. Generate the history UUID,
   enrollment nonce, manifest/configuration digests and authority generation.
5. Emit a redacted approval descriptor for the SDK. It contains identities and
   hashes, not private keys, Kubernetes tokens or transport connection secrets.
6. Make repeated identical installation a validation-only operation. Interrupted
   installation, different files, preexisting authority, missing ledger or changed
   configuration refuses continuation. Supply inspection/remediation documentation
   without an automated reset or an active-domain upgrade path.

Tests: empty/nonempty enrollment, conflicting audit schema, preexisting controller
or runtime resources, ownership/mode and symlink errors, partial installation,
concurrent enrollment, unavailable read-only API/CRI and exact-repeat idempotence.
Verify old lab installation and its source hashes remain untouched.

Exit gate: the endpoint can be installed only through explicit administrator
setup on the approved node. Negative controls cannot grant a new epoch or clear
unresolved evidence. No installer runs during SDK construction or application I/O.

## Phase 3 — Implement protocol and SDK provider

Proposed modules: `SmolBox.Kubernetes.NodeAuthority` and its context/transport/
protocol helpers, implementing `NodeEvidence`. Reuse the existing bounded Port
mechanism and extract shared typed projection code only where behavior matches.

1. Implement exact `SBA1` framing, strict JSON schemas and the three read-only
   actions. Verify the original receipt digest for cleanup and echo request
   nonce/action/identity. Reject duplicate keys and unknown fields/versions.
2. Authenticate using the restricted SSH principal and pinned node host key.
   Use explicit connection parameters and fixed argument vectors; reject unsafe
   host/user/path inputs and disable inherited SSH configuration/agent fallback.
3. Enforce the grant including frame overhead and the protocol body limit before
   allocation. Lock waits, observation children, ledger writes and response output
   share one monotonic deadline. Detect client EOF and kill only owned children.
4. Verify manifest, binding and authority generation against host approvals;
   project the generation into the typed observer epoch. Preserve current
   freshness and version-3 cleanup checks.
5. Map failures to bounded typed errors without credentials, command payloads,
   raw stderr or remote filesystem paths. A helper exit never becomes a workload
   exit. Preserve caller cancellation/death and existing uncertainty semantics.
6. Package all required assets and document construction with no network side
   effects. Keep `LabNodeEvidence` explicitly selectable and never auto-fallback.

Tests: known protocol vectors, short/extra/oversized frames, duplicate/unknown
keys, wrong nonce/action/receipt/epoch/manifest/node, recorded-response replay,
future/stale clocks, authentication/host-key failure, stalled locks and responses,
caller death, child cancellation, tiny aggregate budgets and the 65,536-byte
boundary. Exercise server-side shell/subsystem/forwarding rejection manually
with the installed SSH version; a fake SSH process does not prove that policy.

Exit gate: the provider returns only current typed evidence from the enrolled
authority within the original operation grant. No request can select privileged
commands, roots, credentials, another authority or installation actions.

## Phase 4 — Integrate runtime and persistence contracts

Primary areas: Kubernetes config/provider validation, `Guard`, `KubernetesIO`,
recovery/cleanup, codec/package fixtures, and reference PostgreSQL contracts.
Change these consumers only where the new provider requires it.

1. Add explicit opt-in provider selection and redacted configuration examples.
   Keep the current public execution policy and same-host controller guard.
2. Prove epoch comparison and canonical identity across fresh BEAM processes and
   different atom/module-load orders. Existing HTTP/Embedded encodings and
   fingerprints, and lab v54 fixtures, must remain valid and unchanged in meaning.
3. Run the public Memory and reference PostgreSQL paths through the new provider:
   staging/read-back, real exits, collection, cancellation, unknown recovery,
   original-UID deletion, proof persistence and guarded reservation release.
4. Cover changed approval/epoch during an execution, missing/corrupt authority,
   foreign inventory, paginated startup scans and old lab receipts. Preserve
   charges and frozen admission whenever current authority is unresolved.
5. Retain background recovery with independent worker-lease renewal. Include
   publication longer than a lease, task death, lease loss, exact/small output
   caps, operational byte exhaustion and rejection before application dispatch.
6. Verify the independently unpacked production package contains the full bundle
   and constructs the provider without a checkout, Rust build, SSH connection or
   node mutation. Check shared examples against their existing SDK dependencies.

Exit gate: new-provider contracts pass both stores; existing backend/codec tests
and packaging/docs checks pass. No new feature is advertised by reader support
alone. If durable fields are required, publish and test a separate versioned
upgrade/migration before admitting new-provider records.

## Phase 5 — Manual live qualification and enablement

Use the existing dedicated Linux/K3s lab as the development environment. Schedule
the campaign under its lock and outer-VM cap. Provision a fresh disposable guest
or another explicitly approved empty installation; preserve the previous domain's
records and ledgers. No shared-host runtime replacement or history reset follows
from this document. A fresh VM is a test environment, not a substitute for the
specified positive-empty enrollment checks.

The Mac controller needs verified access to the node SSH endpoint, the existing
verified Kubernetes API path and administrator-provisioned credentials/approvals.
An external tunnel is acceptable. No local Docker/Kubernetes or local SmolVM SDK
is required for this controller/provider campaign.

| Campaign | Required evidence |
| --- | --- |
| Install and access | Exact bundle/configuration hashes; restricted principal can observe but cannot obtain shell, forwarding, arbitrary sudo or mutation |
| Public successful work | Memory and PostgreSQL binary input/read-back/output, silent 0 and real exit 7; one create/application exec; exact artifact hashes |
| Cancellation and uncertainty | Before/after dispatch, lost POST/status, interrupted evidence and missing original Pod; no application replay |
| Durable controller restart | Refuse paused original owner; resume only after positive same-host process death and complete authenticated scan; preserve real exits |
| Authority controls | Wrong endpoint/key/manifest/generation, changed node boot/daemon identity, unavailable mappings and leaked owned path; retain capacity |
| Transport interruption | Close the controller channel during observation; bounded endpoint/child exit, unchanged workload lifecycle and retained original deadlines |
| Final custody | Persist original-UID version-3 proof before zero reserved usage; complete journal/prefix continuity and no unexplained runtime resources |

Do not destroy enrolled infrastructure or create hostile host workloads to obtain
a negative control. Use scoped fixtures/proxies for destructive identity changes;
label those results separately from real node events. Preserve exact failed
observations and do not present a synthetic result as physical failure evidence.

Save a redacted versioned report under `docs/evidence/`, update the source-basis
report, operational guide, parity matrix and implementation progress. Include
remaining bounds, same-host ownership limitation, unsupported history rotation,
upgrade/rollback procedure and recovery escalation. Mark the provider qualified
only for the tested setup after every required live gate passes.

## Validation policy and stop conditions

Run focused Elixir tests per phase, then relevant shared contracts and normal
format/compile/static/package checks. Keep ordinary test discovery intact. Python
tests, installer checks, SSH and live Kubernetes campaigns remain manual; do not
edit `.github/workflows` to provision or validate the node.

Stop enablement if complete history, unchanged lifecycle custody, actual offline
isolation, authenticated endpoint identity, bounded cancellation or proof-bound
release cannot be established. The existing lab preview remains available under
its own approvals. Neither implementation difficulty nor a successful smoke
authorizes weaker proof, broader capabilities or automatic migration.

## Follow-up branches

1. `feature/kubernetes-controller-fencing`: reviewed controller authority
   interface and failure model, with distributed ownership only after positive
   fencing can be demonstrated. Explicitly replace the current concrete guard.
2. Multi-node enrollment/scheduling, node-loss policy and measured capacity:
   separate design with per-node authority and durable assignment constraints.
3. Sources/connectivity and retained-machine/storage families: extend the stable
   authority contracts with their own persisted lifecycle and qualification gates.

Success here establishes a reusable node authority boundary. It does not mark
the entire production-foundation milestone or HTTP/Embedded parity complete.
