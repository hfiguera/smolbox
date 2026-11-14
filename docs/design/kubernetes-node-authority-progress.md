# Kubernetes node authority progress

Status: Phases 0–5 passed for the explicitly approved shim candidate on the tested single-node setup, November 14, 2026. The two failed official-runtime domains remain preserved and charged. Delivery branch:
`feature/kubernetes-node-authority`. Follow the [specification](kubernetes-node-authority.md),
[frozen contracts](kubernetes-node-authority-contract.md) and
[implementation plan](kubernetes-node-authority-implementation-plan.md).

| Phase | State | Evidence |
| --- | --- | --- |
| 0 — Contract and authority review | Passed | Exact schemas, canonical vectors, proof/privilege obligations, source basis and compatibility checks below |
| 1 — Standalone verifier | Passed | Self-contained configured core, source comparison, 53 extraction checks and interruption evidence below |
| 2 — Administrator installation | Passed (fixtures) | Deterministic bundle, explicit root installer and immutable enrollment; live installation remains Phase 5 |
| 3 — Endpoint and SDK provider | Passed (protocol/access scope) | Strict SDK provider, bounded transport, package constructors and real pre-enrollment SSH controls; execution qualification remains Phase 5 |
| 4 — Runtime/store integration | Passed (simulated node observations) | Shared public runtime campaign passes Memory/PostgreSQL, existing compatibility and full suites, package consumers and static/docs gates; physical proof remains Phase 5 |
| 5 — Live qualification | Passed for the explicit candidate setup | Fresh v3 enrollment/access, 12 public cases, two durable recovery controls, original-authority proofs and final custody passed; the two failed old domains remain charged |

## Phase 0 — Frozen v1 data and authority contracts

The [contract checkpoint](kubernetes-node-authority-contract.md) maps every proof
predicate to its source/witness, validator, consumer and negative tests. It fixes
configuration fields, root path rules, allowed observation commands and actor
privileges. `SBA1` requests/responses, exact nested receipts/observations/proofs,
rejections and cross-field constraints have executable validation and JSON schemas.

Python and Elixir agree on canonical configuration/receipt/identity bytes and the
synthetic generation test vector. UUID audit history stays distinct from the
opaque SHA-256 authority epoch. Existing ready receipts reject an epoch change;
old/new proof mismatches cannot release either domain. The new epoch survives
fresh-BEAM v54 decoding without changing any durable layout or legacy encoding.

Read-only checks on `ssh linux` found the existing lab stopped after its four-hour
cap, with no running VM PID and the shared lab lock available. Cached K3s and
SmolVM inputs match their pins. A streamed archive inspection reproduced all six
recorded runtime asset hashes and the qualified 791-entry rootfs manifest digest.
The original VM disk, journal, controller metadata and runtime were not changed.
Current source hashes and the bounded historical source-review chain are in
the [source basis](../../scripts/kubernetes/node-authority/source-basis.json).

Validation: all 87 manual Python checks passed, including ten new contract tests;
seven focused Elixir authority/legacy/cold-codec checks passed. The new cold
authority case explicitly changes atom-loading order. These are data-contract
and source-comparison checks, not node installation or physical proof evidence.

At this checkpoint the endpoint remained unimplemented and unavailable. No new operational selection,
capability, codec version, controller ownership or CI workflow is enabled here.
The remaining phase gates and complete manual Memory/PostgreSQL live campaigns
are still required before qualification or goal completion.

## Phase 1 — Standalone verifier extraction

The private `priv/kubernetes/node_authority/v1/` core observes through an immutable
validated configuration. It imports only its approved bundle and Python stdlib;
it has no lab-home, hostname, smoke/qualification utility, runtime mutation or
guard mutation dependency. The administrator-only history enrollment function
remains separate from the observation entrypoint. Existing lab sources and their
pinned hashes are unchanged.

The extracted history and lifecycle predicates are compared with the original
source AST, allowing only configured paths and the public authority-generation
projection. Capture, cleanup and runtime-health predicates retain their original
structure. Guard rule and netns mapping comparisons use identical inventories.
Bounded filesystem/process/archive helpers replace the former transitive utility
imports. Root custody checks include both sides of installation symlinks; optional
missing health assets do not prevent original-authority cleanup observation.

One deadline covers child observations, lock waits, SQLite busy/progress waits and
ledger publication. Input loss terminates only owned observation children. State
reads reject symlinks, nonprivate files and oversize records. Ledger publication
uses private exclusive partial files, file fsync, atomic replace and directory
fsync; interrupted partial publication is refused rather than repaired. Tests
inject failures at each publication boundary and prove no evidence is returned
when publication fails.

Validation: all 140 manual Python tests passed, including 53 core checks (30
legacy negative/projection cases rerun against the extraction); 14 focused Elixir
node-evidence/authority/legacy/cold-codec checks passed. A temporary real SQLite
journal exercises capture, persisted original UID/lifecycle witnesses and cleanup
through version 3. Kernel/API/CRI/VM/guard observations are fixtures, clearly
separated in the [Phase 1 report](../evidence/kubernetes-node-authority-phase1-2026-11-14.json).
Exact file hashes and intentional differences are in the
[source basis](../../scripts/kubernetes/node-authority/source-basis.json).

No node installation, new enrollment, endpoint, SDK provider or operational
selection exists at this checkpoint. Phases 2–5 and both-store live qualification
remain required. No CI workflow was changed.

## Phase 2 — Offline installation and immutable enrollment

The [administrator guide](../../scripts/kubernetes/node-authority/README.md)
describes deterministic offline bundle construction, fixed installation paths,
root custody, canonical configuration, read-only Kubernetes RBAC and restricted
SSH/sudo policy examples. The installer never provisions a user/key, applies
Kubernetes RBAC, edits/restarts SSH or mutates the offline guard/runtime. These
remain explicit administrator operations on the fresh guest.

Setup validates the approved archive/K3s pins, runtime assets/templates, node
versions and object identity, root-controlled files, source reports and a positive
empty API/CRI/runtime/process/path/guard baseline. Fifteen access reviews require
needed reads and deny Pod mutation/exec, Secrets and broad node/namespace listing;
they never attempt the denied workload operation. Complete role review and real
credential/SSH negative controls remain required during live qualification.

A bounded installer lock serializes setup. Audit enrollment checks emptiness
inside its transaction; runtime/node/lifecycle baselines are checked again before
publishing private ledger, redacted approval and active enrollment in that order.
The fixed framed endpoint refuses the installation marker. An identical repeated
install only validates; explicit verification cannot create missing lock/state.
Different files, an old journal, unexplained controller metadata, missing ledger
or interrupted installation refuse continuation without reset or repair.

Validation: all 159 manual Python tests passed, including 13 installation/bundle
checks and six initial socket endpoint checks. Two independent builds produced
identical archive bytes. An independently unpacked installer runs `--help` with
an isolated interpreter. Fixed shell syntax and Python formatting checks pass.
The [Phase 2 evidence](../evidence/kubernetes-node-authority-phase2-2026-11-14.json)
records exact bundle/tool hashes, real local components and simulated node/root
observations separately. Legacy lab sources and CI workflows are unchanged.

No Linux guest has been installed or enrolled by this phase. The basic endpoint
assets are included so the fixed installed entrypoint is concrete; the complete
protocol/SDK provider gate is still Phase 3. Package/public Memory/PostgreSQL
contracts and all real SSH/RBAC/installation/runtime campaigns remain Phases 4–5.
The provider is unavailable for operational selection and is not live-qualified.

## Phase 3 — Restricted protocol and SDK provider

`SmolBox.Kubernetes.NodeAuthority.new/1` now constructs an explicit redacted
connection/approval context without SSH, credential reads or node installation.
The provider uses direct SSH with a fixed token, pinned host/key files, no
inherited configuration, agent/default-key fallback, proxy/local command,
forwarding or multiplexing. No lab wrapper or API-only fallback exists. The
existing lab projection API delegates to shared typed projection without changing
its wire protocol, approval shape or explicit availability.

The new raw-frame path preserves duplicate JSON keys until strict normalization.
Canonical configuration/receipt/identity vectors agree with Python; schemas,
ASCII/signed-integer/depth/cardinality/body bounds, nonce/action/generation/manifest
matching and exact typed results are enforced. Each invocation gets a fresh
nonce. The original callback deadline includes validation, serialization,
transport and projection; frame overhead is charged. Capture retains future/
five-second freshness checks. Cleanup attaches only the saved receipt, requires
its canonical digest and version-3 proof, and rejects old provider epochs.
Positive evidence requires normal helper completion; even a valid positive frame
with a nonzero helper status cannot become authority. A complete matched negative
frame can report only its bounded rejection, never a workload exit or diagnostic.

Validation: 41 focused Elixir provider/protocol/lab/controller/codec checks and all
159 manual Python checks passed. Strict static/duplication/format checks pass.
Current and minimum production dependency consumers construct the provider with
missing credential/SSH paths and no Rust. The package contains every approved
core/schema/tool asset, excludes bytecode caches, and its independently unpacked
builder works with no test checkout. The existing package validator/smoke now
checks these assets and offline construction. Its macOS temp-root handling was
corrected after a real `/var`/`/private/var` alias produced broken Mix `priv` links.
No CI workflow or node-provisioning/qualification job was changed.

A fresh `node-authority-access-v1` guest ran under the existing shared lock and
four-hour/CPU/memory/task/file limits. Thirty real server controls passed on
OpenSSH 9.6, including shell/subsystem/PTY/environment/sudo/forwarding rejection,
key/host mismatch, missing-key fallback, original endpoint death after client
loss and the real thirty-second partial-header deadline. Four Mac SDK controls
passed through an external tunnel on OpenSSH 10.5. The controls intentionally
returned **unavailable**, with no enrolled authority or K3s/workload/proof claim.

The campaign exposed two policy-example defects: a root-owned authorized_keys
file needs principal-readable public-key permissions, and OpenSSH 9.6 requires
`PermitUserEnvironment` outside Match. Both examples were corrected and effective
policy was verified on the guest. An initial agent-control assertion incorrectly
filtered post-authentication session logs by service unit; comm/syslog filtering
then observed the actual denial. Failed controls and their resolutions are kept
with the [Phase 3 report](../evidence/kubernetes-node-authority-phase3-2026-11-14.json).

The guest and tunnel are stopped, its disk retained and shared lock released.
The original lab disk, failed-by-cap service and authority were not modified.
The [manual tools/guide](../../scripts/kubernetes/node-authority/README.md) describe
reproduction. A separate fresh domain and repeated effective-access checks are
required for final runtime qualification. Default/example selection remains the
lab provider; the new provider is not execution-qualified or operationally
enabled. Phases 4–5 and public Memory/PostgreSQL campaigns remain outstanding.

## Phase 4 — Public runtime and store compatibility

The host settings example keeps Lab as the default and supports explicit
`node_provider: "node_authority"` with separate SSH/approval fields. Unknown names
fail without fallback. Construction and redacted inspection are tested without
existing credentials or a connection. The older-SDK selection guard reports an
unavailable provider instead of silently selecting Lab. The operational guide
shows the redacted shape and keeps execution enablement gated on Phase 5.

A shared 25-scenario public runtime contract now runs against both Memory and
the reference PostgreSQL adapter. It exercises the real standalone SDK, strict
protocol, framed Port and typed evidence validation against explicitly simulated
node observations and TLS Kubernetes/exec peers. These are integration fixtures,
not physical node/SmolVM qualification evidence. Existing lab/controller tests and
production runtime/store code remain unchanged.

Both stores pass binary input staging/read-back, output collection and exit 7;
silent zero exits at caps 1/4096; exact combined binary output and over-limit
uncertainty; cancellation before/after dispatch; lost create/status responses;
occupied-slot queueing; cancelled/expired missing originals; changed generation,
changed manifest, missing/malformed authority; foreign/replacement UID inventory;
old lab receipt refusal; complete paginated startup; and preserved real exit
while cleanup proof is unavailable. Adapter-boundary observations verify that
the original receipt's version-3 proof is already durable while capacity remains
charged, before release produces zero usage. DELETE preconditions retain original
UIDs. v54 round-trips retain the generation and exclude transport/credential paths.

Recovery publication survives a 5.25-second hold across a five-second worker
lease while renewal and accepted admission continue. Task death and lease loss
stop publication, keep the target fenced and retain charges until a supervised
retry completes. Download retries never replay an application command. A valid
command larger than the configured request allowance is rejected before any
application exec request; its durable dispatch intent remains conservatively
unknown until positive cleanup, preserving existing uncertainty semantics.

Validation: the full SDK suite passes **2,363 checks, 42 excluded**; the full
reference PostgreSQL suite passes **335 tests, 29 excluded**, including all 25
new shared scenarios. Format, warning-free compile, strict Credo, zero-clone
ExDNA, xref and Dialyzer pass. Documentation builds with warnings as errors.
Current/minimum production consumers pass without Rust, SSH or a checkout. An
independently unpacked production package builds identical complete authority
archives twice using isolated Python. The package test fixture was updated for
the existing required authority inventory; required-file enforcement is retained.
Minimal-host and community-workspace examples compile against their existing SDK
dependencies, including community-workspace's pinned SmolBox 0.3.0. Its dependency
build emits existing Mix xref deprecation notices; no dependency was upgraded.
An initial concurrent full run hit an existing one-second socket timing assertion;
the unchanged socket test and final full suite pass with bounded test concurrency.

The [Phase 4 evidence](../evidence/kubernetes-node-authority-phase4-2026-11-14.json)
records exact source/log/package hashes, scopes, commands and failed observations.
No durable schema, backend behavior, verifier/core asset, CI workflow or live node
authority changed. The earlier access VM is still stopped with its disk retained;
the shared lock is available. A separate fresh guest, actual enrollment and all
manual live runtime/access/failure gates remain required in Phase 5. The new
provider is **not execution-qualified or enabled**.

## Phase 5 — Qualified explicit candidate; original failures preserved

The original v1 and v2 guests reproduced the pinned SmolVM v1.34.0 startup error
`spawn cp for mount .../etc-hosts: No child processes (os error 10)`. v1 passed
four public cases and v2 passed nine before their failures. Both failed records
retain only created receipts: original Pod deletion and node-wide idle checks
cannot replace their missing ready VM/KVM/cgroup witnesses. Each PostgreSQL
partition still holds one slot, 2 CPUs, 1536 MiB and 30 GiB. Their stopped guests,
records, keys, history and controller metadata remain preserved. The
[Phase 5 report](../evidence/kubernetes-node-authority-phase5-2026-11-14.json)
retains both failures; nothing on the new authority releases their charges.

The separately authorized SmolVM fork fix `ae6c1046` replaces competing child
ownership in the shim. Ordinary helper `Child` handles own their waits; a
background task sweeps the engine's existing per-PID VM registry; unregistered
orphans remain with the supervising ancestor. The real framework/Linux fixture
reproduces a successful copy whose exit is stolen by the default reaper. The
unpatched configuration fails deterministically; the fixed configuration passes
helper success/nonzero/signal/spawn/cancellation/concurrency and copy-metadata
checks, detached VM reaping without liveness queries, and orphan ownership.
Ten shim unit tests and two existing engine reaper/signal tests also pass.

The exact v1.34.0 backport is `b64d2ac8`. Its reviewed shim replaces exactly one
member of the official archive; the other 935 members retain their content and
metadata. Two archive assemblies are byte-identical; the compiled shim was not
independently built twice. The candidate has its own archive/shim hashes and
**does not inherit official artifact qualification**. The default official pins,
shared physical-host runtime and both old enrolled installations are unchanged.
The [fork-fix evidence](../evidence/kubernetes-node-authority-shim-fix-2026-11-14.json)
records exact source/toolchain/asset identities and the actual installed bundles.

A fresh v3 domain ran under the original shared lock and four-hour/resource caps,
with new binding, keys, controller directory and PostgreSQL partition. Positive
empty installation and read-only repeated verification passed, followed by 30
restricted server controls, eight Mac SDK controls and verified TLS/API preflight.
No local Docker, local SmolVM SDK or lab wrapper participated in SDK execution.

All 12 public cases passed on the candidate: both-store binary input/read-back/
output with real exit 7; Memory silent caps 1/4096 and PostgreSQL silent cap 4096;
both-store cancellation after an actual application marker; Memory overflow;
and both-store lost-create and lost-status responses. Each trace records one
create and one application request, except lost-create with zero application
requests. Original-UID version-3 proof was persisted while the reservation was
held, before zero usage. Cleanup often needed the existing delayed read-only
proof retry after its mutation budget; no budget/deadline was expanded.

The durable collection control preserved exit 7, the exact artifact, original Pod
UID and deadlines across positive original-owner death. A paused owner beyond its
five-second lease was refused takeover. Initial and recovered publication each
outlasted the lease with actual renewal events. Killing an observation caller
while the endpoint waited on the original lock ended that endpoint in 596 ms,
without changing the original VMM births or KVM descriptors. A second execution
remained accepted without reservation and was cancelled while queued.

The authority-retention control preserved the real exit/artifact and charge
under synthetic unavailable evidence and separate wrong-manifest/generation
controllers. Restored original approvals completed cleanup and release. Its
private harness initially expected exactly one DELETE; independent trace and
persisted-record audit confirmed two safe deletes guarded by the same original
UID, unchanged original cleanup deadline, one create and one application request.
The failed assertion is retained and explicitly reported; no application was
rerun to correct the harness. Both recovery cases persisted v3 proof before
release and ended with zero usage.

Four labeled counterfactual controls rejected changed boot observation, saved
daemon birth, sandbox mapping and an owned-directory fixture. They changed only
process-local inputs/a separate fixture and produced no release proof; installed
configuration/enrollment/ledger stayed unchanged. These are not claims of actual
node or daemon failure. Final custody found 14 runtime attempts, complete history
at watermark 70, idle node and unchanged exact installation approvals.

The v3 guest is synced/stopped, all owned proxies/controllers/tunnel are stopped
and the shared lock is available. All four pre-existing disks are byte-identical.
Read-only adapter fetches match both complete frozen failed records and their
retained charges. No history reset, receipt migration, forced release, enrolled
runtime/verifier replacement or CI workflow change occurred.

Qualification is limited to the exact candidate hashes, Linux x86_64, K3s
v1.35.10+k3s1/containerd 2.2.10-k3s1, approved Python image, fixed resources and
same-host controller guard. Explicit standalone selection is now supported for
that setup; the default remains Lab. General Kubernetes production support,
distributed fencing, multi-node operation and HTTP/Embedded parity remain future
work. Releasing either old created-only charge needs a separate reviewed proof
and recovery design.

Local validation retains the 2,364-check SDK suite (42 excluded) and 335 reference
PostgreSQL tests (29 excluded) from this Phase 5 snapshot; no SDK/core source was
changed by the shim prerequisite. The updated manual tools pass 181 Python tests,
23 focused Elixir tests, strict Credo/Credence, zero-clone ExDNA and formatting.
Both package dependency lanes and documentation checks are audited separately
against the final source snapshot. The PostgreSQL full suite used a separate
database so its DDL controls could not alter retained live partitions.
