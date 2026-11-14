# Kubernetes node authority progress

Status: Phases 0–1 gates passed, November 14, 2026. Delivery branch:
`feature/kubernetes-node-authority`. Follow the [specification](kubernetes-node-authority.md),
[frozen contracts](kubernetes-node-authority-contract.md) and
[implementation plan](kubernetes-node-authority-implementation-plan.md).

| Phase | State | Evidence |
| --- | --- | --- |
| 0 — Contract and authority review | Passed | Exact schemas, canonical vectors, proof/privilege obligations, source basis and compatibility checks below |
| 1 — Standalone verifier | Passed | Self-contained configured core, source comparison, 53 extraction checks and interruption evidence below |
| 2 — Administrator installation | Pending | No new node installation or enrollment |
| 3 — Endpoint and SDK provider | Pending | Pure data contract exists; no runnable endpoint/provider |
| 4 — Runtime/store integration | Pending | Preliminary epoch/codec compatibility only; provider/store campaigns remain required |
| 5 — Live qualification | Pending | Existing lab evidence does not qualify this provider |

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
