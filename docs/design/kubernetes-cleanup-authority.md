# Kubernetes cleanup authority — Phase 6 checkpoint

Status: version-3 node proof and controller recovery implemented, November 13,
2026. Public API qualification is in progress. This document describes the
narrow lab authority model; it is not a production Kubernetes fencing design. Follow
[progress](kubernetes-backend-progress.md) and the
[delivery plan](kubernetes-backend-implementation-plan.md).

## Implemented lifecycle

Preparation writes create dispatch intent before its single POST, saves the
original UID before waiting for readiness, and persists the ready receipt and
machine before staging. A rejected but identifiable mutated Pod still saves its
UID. Lost responses reconcile full saved intent through GET; they never send a
second POST. A missing original object without a saved mapping stays unresolved.
Read-only first-capture retries share one preparation deadline and aggregate
operation byte budget. They cannot authorize a replacement incarnation.

The Kubernetes cleanup branch precedes generic not-found and stop handling.
Explicitly pending creation can save not-dispatched evidence and release without
calling the backend. After dispatch intent, only the owned UID is disposable.
An API 404 alone never completes cleanup. Known UIDs may be deleted after a
readiness rejection, while their reservation remains held without physical proof.

Cleanup saves a fresh matching proof before guarded store release. Original
command results and collection outcomes survive cleanup failures. Mutation
attempts and their absolute deadline are bounded; afterward only a fresh bounded
read-only observation may finish existing cleanup. Neither the stage deadline
nor the application command is restarted. Failed proof writes, lost write
responses and failed releases preserve enough authority for a guarded retry.

A private host controller ledger now records the original BEAM PID, OS process
birth, boot and host identity, binding generation, and complete bounded owner
history. An expired database lease, a paused controller, or a helper's exit does
not permit takeover. A new owner requires positive original-process death or a
changed birth/boot on the same host. The ledger is never reset by recovery.
A newly created ledger remains unenrolled until an authenticated empty store
scan and empty API/node inventory pass. Existing assignments cannot be adopted
through reset host metadata.

Startup freezes both admission and existing execution tasks. It authenticates
one complete assignment record per page, including tombstones, checks original
binding/owner history, and classifies all assigned work. Ready commands wait for
the complete scan and fresh original-incarnation checks. Dispatching/running work
becomes unknown without execution; durable real exits permit safe collection.
Unresolved cleanup, foreign inventory, corrupt pages or missing authority keep
the fence closed. Inspection returns bounded, redacted API observations and
charged-but-missing assignments as unresolved; it never authorizes release.

## Proof versions and current limits

The struct field layout and selective v54 record envelope remain unchanged.
Versions 1 and 2 remain historical data that can decode without rewriting their
authority. Neither can release capacity. Version 2 added original-UID CRI sandbox
absence; version 3 additionally requires the persisted original Pod-cgroup
witness, its subsequent absence, and unchanged daemon births/cgroup mount.
Both Memory and reference PostgreSQL stores require version 3 for release.
There is no silent proof upgrade.

## Kubelet lifecycle investigation

The enrolled K3s release's
[dependency manifest](https://raw.githubusercontent.com/k3s-io/k3s/v1.35.10%2Bk3s1/go.mod)
pins the Kubernetes fork at `v1.35.10-k3s1`. Reviewed kubelet files are byte-identical
to the upstream `v1.35.10` counterparts at the
[recorded source hashes](../../scripts/kubernetes/kubelet-lifecycle-source-basis.json).

The [Pod-worker state machine](https://raw.githubusercontent.com/k3s-io/kubernetes/v1.35.10-k3s1/pkg/kubelet/pod_workers.go)
tracks in-flight work separately from desired API objects. The
[kubelet lifecycle](https://raw.githubusercontent.com/k3s-io/kubernetes/v1.35.10-k3s1/pkg/kubelet/kubelet.go)
creates the Pod cgroup before runtime synchronization and destroys it during
terminated-Pod cleanup. The
[orphan cgroup cleanup](https://raw.githubusercontent.com/k3s-io/kubernetes/v1.35.10-k3s1/pkg/kubelet/kubelet_pods.go)
excludes workers that may still be running or terminating. Ordinary Pod-directory
cleanup has different conditions and is not sufficient as a lifecycle witness.

The fixed lab durably witnesses the original guaranteed-QoS Pod cgroup during
ownership capture and requires its absence after UID deletion, with the same
cgroup mount, node boot and K3s/containerd PID births. Missing or replaced
witnesses fail closed. The inference from the reviewed pinned kubelet callers
is that this closes original-worker lifecycle activity under the documented
exclusive-principal/no-UID-reuse assumptions. The implemented version-3 path
passed live capture, shared cleanup, proof persistence and guarded release to
zero Memory slots. Daemon restart invalidates this authority; it does not grant
automatic recovery. This is a narrowly qualified lab mechanism.

The live feasibility probe found the exact guaranteed-QoS Pod cgroup before
UID deletion and found it absent after API/CRI/VM collection. K3s and containerd
retained their process births and shared embedded executable identity. Containerd
is a K3s multicall process; selecting its wrapper executable was an incorrect
initial assumption, corrected through read-only process inspection. The probe's
application was never dispatched, and its lost ephemeral store is not presented
as a successful persisted release.

This cgroup witnesses kubelet lifecycle progress only. SmolVM's VM processes
remain outside Pod cgroups in the qualified runtime. It does not establish VM
resource enforcement or replace original KVM/PID/SDK/path termination evidence.

## Administrator maintenance performed

With all prior component drivers exited and the preview namespace empty, the
manual `upgrade-node-inspector` command verified empty API/CRI/VM/reservation/
process/path state and complete ownership history. It retained all 50 existing
journal events, the ten sandbox ownership mappings, the journal prefix hash,
SQLite triggers and database inode. Only the epoch and approved inspector changed:

- Prior epoch: `249f9047-69ca-4312-9d38-c3442e9813b9`.
- Version-2 epoch: `effbd777-274c-42b2-b9b7-00cd0abf78e1`.
- Version-2 inspector SHA-256: `800f8d58af96a12dfd9c7ec4dbfc03f07c0a57bdfab0ba66c65ccdbc570dc683`.
- History program SHA-256 stayed `8cf6195deaba11145afea2bd9c5fa5c94b30be04e0fc364764d57d1cefb42c5f`.

The ordinary installer still refuses replacement or history reset. This narrowly
approved maintenance tool preserves the original enrollment/ledger in its root
plan, records its complete new approval, and refuses automatic continuation after
an interrupted/different upgrade. It is not an application repair operation or
a way to discard unresolved executions. Controllers must already be positively
quiescent before an administrator invokes it.

The real shared preparation/files/cleanup component run preserved exit 7 and
exact binary artifacts. Instrumentation recorded two failed capture observations
that were retried, fourteen failed cleanup observations with capacity retained,
and a final version-2 proof followed by guarded release to zero slots. A prior
preparation failed with unavailable node evidence before application dispatch;
its precise rejected subcheck remains unproven. Its original intent was reconciled
and positively collected without replay or a reconstructed store-release claim.

All cluster and Python checks remain manual. No CI workflow changes accompany
this work. This historical version-2 checkpoint preceded the version-3 and controller
qualification described below; it is not current release authority.

## Version-3 maintenance and live authority

A second verified-empty administrator transition retained all 65 events and 13
sandbox owners from the prior prefix, then installed the approved lifecycle
module and inspector. It preserved the database inode, audit schema and original
ownership mappings. Current epoch: `5289f8c3-94e9-4f77-b578-348f4772adbe`.
Current inspector SHA-256:
`ce2a3d2071e1fb051b53c385730483462e16e909684358c6c0c93175beea36b6`.
Lifecycle SHA-256:
`cc138716a7a22e1d22c33f26cb8188cc5b11937d19fa27acfe643400126d288e`.
History source remains unchanged. The maintenance helper accepts only this exact
reviewed old-to-new transition and refuses changed or partial plans.

The real public Memory and PostgreSQL runs saved version-3 proof and observed
zero slots after binary collection with exit 7. The durable controller fault
campaign refused paused-owner takeover, retained its ledger, then recovered the
same running execution after positive original BEAM death. It kept the result
unknown, issued no new submit during resume, deleted the original UID, persisted
version-3 proof and released capacity. Public cancellation also completed with
unknown result and positive original-UID proof. See the final phase evidence for
source revisions, deterministic no-second-exec controls and exact outcomes.

## Same-host controller prerequisites

The manual Mac controller requires an absolute Python 3 executable and a private
0700 local guard directory. Fixed helpers use OS process identity only; they do
not receive database secrets or mutate Kubernetes. Keep the same directory and
same durable store partition across restarts. Do not copy, delete, restore from
snapshot, or share its ledger between hosts. Missing/corrupt state or exhausted
bounded history requires administrator investigation, not an automatic reset.
The Mac OS protocol test refused takeover while the original process was stopped
with SIGSTOP and allowed it only after observed death, preserving owner history.
Durable public restart qualification is recorded in the progress log.
