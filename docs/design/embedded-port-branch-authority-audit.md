# Embedded branch authority and sibling accounting audit

Status: partial implementation evidence, October 16, 2026. This audit follows
P8.4–P8.6 of the [parity plan](embedded-port-http-parity-implementation-plan.md).
It distinguishes supported original-owner transitions from uncertainty that must
retain resources. It does not close ordinary SDK, package or platform acceptance.
Public native branch admission remains disabled; crash validation stays deferred.

## Original owner states

The authoritative state is the original retained job or completed context,
combined with its protected journals and opaque epoch enrollment. A caller's
quiescence assertion, SDK inventory, directory absence or serialized receipt
cannot reconstruct that authority. `BranchPreparationState` is observational;
its name alone grants no lifecycle transition or accounting release.

| Original state or boundary | Allowed next step and required evidence | Resources retained |
| --- | --- | --- |
| Prepared, before worker entry | Exact prepared retirement, with the original unused grant and protected declaration | Source remains owned; no invented child completion |
| Worker entered or still active | Observe the same worker handle; no replay, disposal or handoff while active | Original job, gates and backing |
| Verified worker output, before source publication | Publish only the original verified snapshot and matching source authority | Child preparation and backing |
| Published child, boot not entered | Explicit unbooted disposal under the exact original declaration, or continue the original creation | Source dependency and backing until separate retirement/closure |
| Boot entered, no returned enrollment | Preserve uncertainty; phase, PID files and empty inventory cannot manufacture an original collected child | All original work and backing |
| Boot returned, including failed lifecycle publication | Retained return facts preserve the original manager/enrollment. Explicit collection needs positive original epoch collection | SDK row, disks, dependency and backing remain after collection |
| Identity or release entered, worker returned | Qualify an already completed protected result; otherwise retain uncertainty or explicitly collect/dispose the original child | No readiness or release inferred from SDK flags |
| Identity ready or released, before handoff | Revalidate original live enrollment, source authority and synchronized lifecycle/material history, then transfer the same manager | Persistent backing and bounded completion metadata |
| Partial disposal entered | Observe the existing one-shot deletion. Never replay SDK entry from a primary journal alone | Original gates/work until terminal archival; dependency/backing afterward |
| Exact cleanup enrolled but never attempted, child already absent | Two original-context absence/source observations plus cache, actor and root provenance can publish ResolvedAbsent; separate handoff and unnecessary-cleanup acknowledgement follow | Dependency and backing; no new removal or SDK grant |
| Completed held child | Explicit release or deletion using the completed original context. Ordinary start/stop/commands remain blocked | Independent child and backing reservations until their respective proofs |
| Completed released child, original manager active | Ordinary work/stop or explicit deletion using that manager and opaque enrollment | Source dependency and backing |
| Released child after normal stop/restart | Ordinary receipt-bound lifecycle uses current handles. Retired-original deletion additionally requires no active handles, exact protected released head, canonical stopped row and positive original collection | No authority borrowed from a later active handle |
| Child deletion proved | Explicit paired dependency retirement with the exact child version and typed absence proof | Backing remains charged; sibling dependency is unchanged |
| Source and child absent, dependency retired | Persist an exact backing request and consume its matching acknowledgement with explicit host removal confirmation | Other children's allowances remain charged |
| Original context missing, crossed or substituted | Reject or retain uncertainty; never adopt a manager or release capacity from labels or absence | Existing reservations and histories |

Source references:
[retained states and registry](../../native/smolbox-engine/src/branch/retention.rs),
[original resolution](../../native/smolbox-engine/src/branch/retention/resolution.rs),
[ready handoff](../../native/smolbox-engine/src/branch/retention/resolution/ready.rs),
[retained boot facts](../../native/smolbox-engine/src/branch/retention/boot.rs),
[partial collection](../../native/smolbox-engine/src/branch/retention/resolution/collection.rs),
[partial disposal](../../native/smolbox-engine/src/branch/retention/resolution/partial_disposal.rs),
[unused cleanup absence](../../native/smolbox-engine/src/branch/retention/resolution/partial_disposal/archive/unused_absence.rs),
[completed collection](../../native/smolbox-engine/src/branch_owned/collection.rs),
[retired-original deletion](../../native/smolbox-engine/src/branch_delete/collected.rs).

These are source-level boundaries, not universal recovery claims. In particular,
missing enrollment or foreign/used cleanup history is not a reason to add an
absence-based shortcut. Remaining required transitions must be established from
their actual original authority before their implementation can be called complete.

## Paired sibling contract

The [shared sibling contract](../../test/support/store/native_branch_sibling_contract.ex)
drives actual Memory and encrypted PostgreSQL store operations with synthetic
native proofs. It covers all nine held/initially-ready/explicitly-released sibling
pairs in both retirement orders, for 18 cases per adapter and toolchain:

- A second publication appends to the source's current material head, preserving
  the first child's record and immutable source creation.
- Deleting one child releases only its ordinary allocation. Retiring its exact
  dependency preserves the sibling and both backing allowances. Source stop
  remains blocked until the other dependency is also retired.
- A valid proof for the sibling cannot retire the selected child's dependency.
  Rejection preserves both records and usage; exact retries are idempotent.
- Backing acceptance rejects while the source exists. After source deletion,
  both backing requests can remain pending independently without releasing usage.
  A sibling's valid acknowledgement cannot close the other request.
- Each matching acknowledgement releases exactly one extra allowance, preserving
  the other pending/closed record and append-only source history. Both closures
  leave zero reserved capacity, and exact retries do not release capacity twice.
- Source and child records round-trip through the real codec at each retirement
  and backing boundary.

This contract supplies no native SDK enrollment, VM disk/memory independence,
manager cleanup, helper replacement or installed consumer evidence. P8.6 still
requires ordinary sibling workloads, held release, normal child restart and
explicit dependency/backing cleanup for each supported source/platform combination
on the exact rebuilt package. The broader P0–P9 acceptance matrix stays pending.
