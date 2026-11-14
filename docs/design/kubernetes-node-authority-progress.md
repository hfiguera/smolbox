# Kubernetes node authority progress

Status: Phase 0 contract gate passed, November 14, 2026. Delivery branch:
`feature/kubernetes-node-authority`. Follow the [specification](kubernetes-node-authority.md),
[frozen contracts](kubernetes-node-authority-contract.md) and
[implementation plan](kubernetes-node-authority-implementation-plan.md).

| Phase | State | Evidence |
| --- | --- | --- |
| 0 — Contract and authority review | Passed | Exact schemas, canonical vectors, proof/privilege obligations, source basis and compatibility checks below |
| 1 — Standalone verifier | Pending | No extracted verifier yet |
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

The endpoint remains unimplemented and unavailable. No new operational selection,
capability, codec version, controller ownership or CI workflow is enabled here.
The remaining phase gates and complete manual Memory/PostgreSQL live campaigns
are still required before qualification or goal completion.
