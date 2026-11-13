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
| 1 — Target and authority types | Pending | Config, binding, assignment, receipt and identity validation |
| 2 — Store/codec/OCI admission | Pending | Atomic authority and compatible persisted formats |
| 3 — Object lifecycle | Pending | Restricted credentials and bounded API client |
| 4 — Exec | Pending | Elixir WebSocket client and application helper |
| 5 — Files | Pending | Qualified helper staging/collection |
| 6 — Cleanup/recovery | Pending | NodeEvidence provider, positive cleanup proofs and restart reconciliation |
| 7 — Public qualification | Pending | Public SmolBox smoke, compatibility evidence and user documentation |

No Kubernetes backend is implemented or enabled yet. Phase 0 demonstrates the
upstream runtime and resolves its network recipe; it does not substitute for
the later library, store, recovery or public-path gates.

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
