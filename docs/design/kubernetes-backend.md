# Kubernetes backend

Status: first development preview qualified, November 13, 2026.
This document defines the Kubernetes backend direction and its first development
preview. Follow [current progress](kubernetes-backend-progress.md) and exact
phase evidence for implemented/qualified capabilities. The delivery sequence is in
[the implementation plan](kubernetes-backend-implementation-plan.md).

## Long-term goal: HTTP and Embedded parity

**The long-term goal is feature parity with the HTTP and Embedded backends
through the same SmolBox public APIs and behavioral contracts.** Kubernetes is
intended to become a full backend for managed execution and machines. The narrow
preview below is the first milestone toward that goal, not a permanent feature
ceiling.

Parity covers lifecycle and retained data, execution modes, files, sources and
credentials, networking/ports, volumes, images, measurements, exports,
checkpoints, branches, and their admission/recovery/cleanup semantics. Kubernetes
uses its own transport and ownership model while preserving those domain
contracts, including byte fidelity, uncertainty, identity and capacity accounting.

Deliver parity one capability family at a time, with an explicit coverage matrix
against HTTP and Embedded and shared public contract tests. Some capabilities
will require additional infrastructure or upstream SmolVM changes. They remain
tracked parity gaps until implemented and qualified; Kubernetes API availability
alone cannot enable them. Unsupported operations continue to fail explicitly.

See [implementation progress](kubernetes-backend-progress.md) and the
[parity matrix](kubernetes-backend-parity.md) for current evidence and gaps.

## Decision and first release

Add `SmolBox.Backend.Kubernetes` behind the existing domain-operation boundary.
SmolBox owns execution intent, admission, artifact collection, uncertainty, and
cleanup accounting. Kubernetes schedules a Pod; containerd selects the upstream
SmolVM shim through a RuntimeClass; the shim creates the microVM. The adapter
uses the Kubernetes API directly. It does not call the SmolVM HTTP server, run
the Embedded Port backend, or shell out to `kubectl` for application operations.

The first release supports **disposable managed executions on one explicitly
enrolled Linux x86_64 node in one cluster and one dedicated namespace**. The user
submits an approved OCI source, foreground command, and bounded input/output
manifest through the existing managed execution API. Each execution gets one
bare Pod, one workload container, and one sandbox VM. The container stays alive
while files are staged, the command runs, and outputs are collected; then the
Pod and its VM are deleted. Neither a Job nor a Deployment owns the Pod.

This is a development preview because network isolation, resource accounting,
and positive node cleanup evidence still need qualification. A passing runtime
smoke is necessary evidence, not proof that these backend contracts hold.
Do not advertise Kubernetes support before the release gates below pass.

| Area | First release | Deferred |
| --- | --- | --- |
| Deployment | One enrolled K3s node; one active controller per target | Multi-node pools, HA/failover, arbitrary distributions |
| Public entry point | `SmolBox.submit/2`, fetch/await/cancel and declared artifacts | `SmolBox.Machines` retained lifecycle and attached commands |
| Source | Approved Linux amd64 OCI platform manifest by SHA-256; public pull | Tags/index resolution, private registry credentials, `.smolmachine`/checkpoint sources |
| Image contract | Qualified image with Python 3, neutral keeper, writable `/workspace` | Arbitrary/minimal images, distroless compatibility |
| Execution | One foreground argv command; env; `/workspace` workdir; raw stdout/stderr; observed exit | Command stdin, user selection, background exec, PTY, reconnect |
| Files | Regular files beneath `/workspace`; atomic staging; bounded binary collection | Symlinks, directories, archives, enlarged transfer budgets |
| Resources | One verified fixed VM shape and explicit admission overhead | Dynamic VM sizing, quotas inferred from container requests |
| Network | Qualified namespace-wide ingress/egress deny; image pulls happen on node | Allowlist translation, services, ports, ingress, port-forward |
| Cleanup | UID-preconditioned graceful delete plus positive node evidence | Force deletion, automated failed-node recovery |
| State | Durable intent/Pod receipts; observation-only restart reconciliation | Replaying commands, adopting by label/name, relocating executions |
| Storage/features | Ephemeral container filesystem | PVC/CSI, host mounts, volumes, exports, checkpoints, branches, growth, GPUs |
| Validation | Explicit manual offline and Linux lab commands | Changes to CI workflows or automatic use of `ssh linux` |

“Disposable” describes workload lifetime, not the store. A durable store remains
necessary to recover ownership after controller failure. A memory store is only
appropriate for explicitly ephemeral development; lost authority requires lab
inspection, not automatic adoption or sweeping deletion.

## Evidence and source basis

The [lab guide](../kubernetes-lab.md), [pins](../../scripts/kubernetes/pins.json),
and [November 13 live evidence](../evidence/kubernetes-lab-2026-11-13.json) establish
K3s `v1.35.10+k3s1`, containerd `2.2.10-k3s1`, and the upstream SmolVM `1.34.0`
Linux distribution. The smoke verified a distinct guest kernel, real KVM
descriptors, binary input/collection, exit 7, and disappearance of the original
VM process, machine record, VM directory, and share. It also passed after an
outer-VM restart and reprovisioning. That restart did not test an in-flight
execution surviving node failure.

The reference checkout is `f9e93d8ffe2215130cc81de1cec365c92c46a869`
(`v1.34.0-32-gf9e93d8f`). It is ahead of the release: source observations must be
checked against tag `v1.34.0` and the downloaded distribution before enabling a
feature. Its [Kubernetes guide](../../external-references/smolvm/docs/kubernetes.md),
[shim engine](../../external-references/smolvm/crates/smolvm-shim/src/engine.rs),
[task service](../../external-references/smolvm/crates/smolvm-shim/src/task.rs), and
[RuntimeClass](../../external-references/smolvm/deploy/kubernetes/runtimeclass.yaml)
explain the upstream path:

1. containerd mounts an OCI rootfs and passes its task bundle to the shim.
2. Sandbox creation boots a persistent, runtime-managed VM named by CRI sandbox
   ID; the VM is connected to the Pod network namespace when one is supplied.
3. The shim materializes the container rootfs and mount data into a per-sandbox
   share and invokes guest `PodCreate`, `PodExec`, and `PodStart` operations.
4. A pump forwards agent output/exit and containerd FIFO input. Sandbox deletion
   tears down the VM and its share. Source cleanup paths include best-effort
   behavior, so successful API mutation cannot substitute for physical evidence.

The shim uses the same embedded engine as upstream SDKs. SmolBox does not need
an SDK binding for this backend: the Kubernetes control and exec APIs are its
integration surface. The upstream RuntimeClass declares 250m CPU / 160Mi memory
overhead, but the shim's sandbox constants are 2 vCPUs / 1,024 MiB. These are
different quantities; the RuntimeClass defaults are not a sufficient reservation
for the VM. Container resource fields do not change those VM constants.

## Architecture and ownership boundaries

```text
SmolBox.submit / await / cancel
              |
Runtime coordinator + authenticated store + artifact store
              |
Backend.Kubernetes + Kubernetes target/assignment validation
         /                         \
HTTPS object API + WebSocket exec    bounded NodeEvidence provider
              |                                  |
Kubernetes API -> kubelet -> containerd      node-local observation only
                              |
                    containerd-shim-smolvm-v2
                              |
                       sandbox microVM
```

The BEAM controller can run on the Mac or on Linux. Only the Kubernetes worker
needs Linux/KVM. The existing single-VM lab remains the reference environment;
ordinary Docker/Kind containers on the Mac are not a substitute for nested KVM.

Administrators install K3s, the pinned complete SmolVM runtime, RuntimeClass,
node labels, namespace, service account/RBAC, network policy, and node evidence
access. Runtime credentials cannot install a shim, mutate containerd, change
node labels, create namespaces, or modify the policy that constrains workloads.

The first release has one active SmolBox controller per enrolled target. Store
claims serialize orchestration, but are not Kubernetes fencing tokens. Taking
over an expired claim does not revoke a request already accepted by Kubernetes.
Recovery must establish old-controller quiescence before admitting new work;
uncertain commands are never replayed. Kubernetes Lease objects are not proposed
as an atomic exec fence.

## Target configuration and enrollment

Introduce a separate `SmolBox.Kubernetes.Config`. Do not overload HTTP
`WorkerConfig` or the Embedded package descriptor. Proposed fields are:

| Field | Meaning |
| --- | --- |
| `id` | Stable logical target ID; existing store `worker_id` continues to carry it |
| `api_server`, `ca_file`, `credential_provider` | Explicit HTTPS endpoint, trusted CA, bounded auth resolver |
| `cluster_id`, `cluster_anchor_uid` | Operator identity and enrolled `kube-system` namespace UID; no portable built-in cluster UUID is assumed |
| `namespace`, `namespace_uid` | Existing dedicated workload namespace and immutable incarnation |
| `node_name`, `node_uid`, `node_boot_id` | Single permitted node and enrolled boot identity |
| `runtime_class`, `runtime_class_uid`, `runtime_policy_digest` | Class identity and approved handler/scheduling/overhead configuration |
| `runtime_identity` | SmolVM archive/shim hashes, K3s/containerd versions, qualification revision |
| `sources`, `profiles`, `capacity`, `allocation_floor` | Exact approvals; no caller-controlled Pod spec |
| `node_evidence` | Required bounded provider for sandbox identity and positive cleanup |
| `qualification`, `draining`, `budgets` | Development-only qualification, admission switch, object/exec limits |

The target/authority constructors and object API are now implemented; follow the
progress document for remaining preview gates. Client auth
supports an explicitly configured bearer-token file (including an in-cluster
projected service-account token) or a host callback. Read rotating token files
within the operation budget. The first release does not interpret arbitrary
kubeconfigs, execute credential plugins, or invoke cloud CLIs. Resolve Mac
development credentials explicitly from the lab's private kubeconfig; retain
TLS verification and never save credentials in the repository.

Enrollment verifies the cluster anchor, namespace, node and RuntimeClass UIDs,
approved runtime and policy identities, and required store capabilities. A URL
or cluster nickname is insufficient. Bind the target ID to this domain in the
store before admission. A changed namespace/node incarnation, node reboot,
runtime or policy requires explicit requalification; it cannot silently reuse
an existing target binding. Do not equate a name/label match with attestation.

Initial defaults: one slot, one active execution, one enrolled node; object
requests/responses bounded to 2 MiB, exec output default 1 MiB, individual files
at most 1 MiB, total files per direction at most 4 MiB. Existing profile stage
deadlines remain authoritative and may only be tightened by target limits.
Preparation must allow a cold image pull/boot; the default 60 seconds is not
automatically sufficient. No watch or credential refresh may reset a deadline.

The initial API surface is deliberately small:

| Request | Purpose |
| --- | --- |
| `GET /version` | API compatibility observation |
| `GET /api/v1/namespaces/{name}` | Enrolled workload/cluster-anchor identity |
| `GET /api/v1/nodes/{name}` | Enrolled node UID, boot identity and readiness |
| `GET /apis/node.k8s.io/v1/runtimeclasses/{name}` | Runtime handler and approved scheduling/overhead |
| `GET /apis/networking.k8s.io/v1/namespaces/{ns}/networkpolicies/{name}` | Approved policy configuration; enforcement is qualified separately |
| `POST /api/v1/namespaces/{ns}/pods` | Create the saved intent once |
| `GET /api/v1/namespaces/{ns}/pods[/{name}]` | Bounded inventory or original-Pod observation |
| `GET /api/v1/namespaces/{ns}/pods/{name}/exec` | WebSocket upgrade with constant helper argv |
| `DELETE /api/v1/namespaces/{ns}/pods/{name}` | Graceful UID-preconditioned deletion |

`Runtime.Target` needs explicit Kubernetes clauses for normalization, validation,
connection, endpoint identity, eligibility, qualification, and allocation.
`Backend.Features` must use a Kubernetes allowlist, never the existing fallback
that infers HTTP capabilities from `runtime_version`. `sdk_version` is not a
Kubernetes capability signal. HTTP and Embedded behavior stay compatible.

## Persisted authority and compatibility

Use new typed `SmolBox.Kubernetes.Binding`, `Assignment`, `Receipt`, and
`CleanupProof` structures. Do not put Kubernetes maps into the Embedded
`Backend.Assignment` schema or fabricate an Embedded receipt/PID. Introduce
explicit dispatch in shared assignment/binding validation where it currently
assumes Embedded. Proposed durable data:

| Structure | Required facts |
| --- | --- |
| Binding | Target ID, cluster anchor UID, namespace UID, node UID/boot ID, enrollment generation, runtime/policy digest |
| Assignment | Binding, schema version, generated DNS-safe Pod name, random creation nonce, exact approved OCI source, normalized Pod intent and digest, execution key/fingerprint, resource reservation |
| Receipt | Original Pod UID, namespace UID, admitted intent digest, node UID/boot ID, workload container name/ID and image identity, observed restart count, node-evidence sandbox/process mapping |
| Cleanup proof | Same binding/Pod UID, known sandbox identities, original process births, node observation epoch/time, Pod absence, scoped record/directory/share absence, verifier identity |

Generate the Pod name and nonce once, atomically with reservation and assignment,
before the POST. Keep the name short enough for Kubernetes DNS rules; do not
reuse the general `Identity.machine_name` output without validating those rules.
Never reuse a Pod name, including after deletion. Keep released assignment
tombstones in authenticated recovery scans.

Add optional `backend_receipt`, `backend_cleanup`, and `backend_create_state` execution fields, nil for
existing records. Immutable creation intent stays in `backend_assignment`.
Store a creation receipt under the current claim/version before staging or exec.
Updates may fill in initial runtime observations but may never substitute a new
Pod UID, node, sandbox incarnation, or workload container for the original one.
The node verifier must account for every sandbox attempt associated with the
original Pod UID, not just the most recent successful container.

The existing `Machine.backend_identity` accepts only Embedded identity, and
`ExecutionValidation` routes all assigned observations through that validator.
Add a typed Kubernetes identity and explicit comparison/validation. Its
`created_at` is nil; Pod UID and the receipt carry identity. Do not turn a
Kubernetes timestamp into ownership or invent a host PID visible through the
object API. `Machine.same_incarnation?/2` must compare the binding, Pod UID and
qualified container/sandbox identity, while allowing only documented state
transitions. API resourceVersion is a concurrency value, not an incarnation.

Add a selective codec envelope for Kubernetes records; choose the next available
version at implementation time. Existing HTTP/Embedded bytes and fingerprints
must remain unchanged. Every reader, projection writer, reservation transaction,
and host-store adapter must support the new union before advertising
`kubernetes_backend: 1`. This marker includes binding, receipt transitions,
cleanup-proof validation, complete recovery scans and source admission; existing
`registry_sources: 1` alone is insufficient. Extend `bind_backend` and
`backend_assignments` deliberately; do not bypass those authority boundaries.
Mixed-version controllers must be upgraded before target enrollment.

## OCI execution admission and lifetime policy

The managed public API currently permits remote OCI identities only for
retained-machine commands; `SmolBox.submit/2` explicitly rejects disposable
remote sources. Supporting this backend therefore needs an explicit additive
disposable OCI path through both public admission and spec validation. Reuse
`Source.oci/1` and `Source.artifact/1`; the digest is a **platform manifest** digest,
not a layer, image config, index, or `.smolmachine` content hash. Match the entire
source against the configured catalog. Do not rename it a local artifact to pass
the current validation.

Only Kubernetes targets with `kubernetes_backend: 1` admit that new disposable
source path. Existing HTTP disposable-source behavior remains unchanged. The
container image is always `registry/repository@sha256:...`, `imagePullPolicy: IfNotPresent`;
verify its runtime image identity against a qualified digest-resolution rule.
Record the raw imageID but do not assume every CRI imageID is the same digest
kind as the requested manifest. Registry pulls happen on the node; guest offline
policy does not prevent them or bound image cache/rootfs copying.

The image contract requires Python 3, a neutral keeper, `/workspace`, and the
fixed helper behavior described below. The current BusyBox smoke qualifies the
runtime path only; it does not qualify this new application image. Pin and test
at least one suitable image before the preview can ship.

Kubernetes cannot stop a Pod and later restart its same writable filesystem
through the required VM lifecycle contract. Require **explicit
`retention_ms: 0`** for Kubernetes disposable executions: after an unknown outcome,
delete the Pod rather than promise retained-machine forensics. Extend validation
to accept exactly zero for this newly gated path, alongside the existing positive
range; preserve all existing defaults and historical encodings. Other backends
keep their existing admission rules. A caller using the existing positive default
receives an unsupported-capability error before reservation. Do not silently
discard the requested retention or emulate stop/start by creating another Pod.

Admission also rejects non-nil command stdin/user, background mode, non-default
guest paths/workdir, terminals, image pulls as guest commands, mounts, volumes,
ports, workloads, non-OCI sources, network allowlists, unqualified profiles and
arbitrary Pod patches. Unsupported options fail with `:not_dispatched` evidence.

## Pod template and lifecycle mapping

Use a bare Pod with an explicit name, no owner controller and no automatic retry:

- `runtimeClassName` is the enrolled SmolVM class; `restartPolicy: Never`.
- One container, fixed name `workload`, the approved digest image, neutral Python
  keeper; no init containers, sidecars or injected workload agents.
- Node selection includes the enrolled hostname and `kubernetes.io/arch: amd64`;
  verify the resulting node name and UID. Let the scheduler bind it; do not
  bypass scheduling with an arbitrary caller-supplied `nodeName`.
- No service-account token, host network/PID/IPC, privileged mode, hostPath,
  extra devices, host ports, GPU annotations, or caller-controlled lifecycle hooks.
- Apply qualified non-privileged security settings, dropped capabilities,
  no privilege escalation, and a qualified seccomp configuration. Root inside
  the guest may be needed initially; do not claim the restricted Pod Security
  profile or effective enforcement before testing this exact shim/image.
- A bounded termination grace period; no liveness restart or active deadline
  that could destroy the container before collection. Controller crash can leave
  the keeper running; the durable reconciler owns cleanup. A lab VM timer is a
  separate safety bound, not backend cleanup evidence.
- Metadata carries bounded opaque execution/intent identifiers and a digest,
  never raw scope IDs, commands, env, input bytes, credentials or secret hashes.
  Admission mutation is checked against a canonical effective-spec allowlist.
  Unexpected sidecars, mounts, images, runtime changes or security changes fail
  before exec; delete only after receipt ownership is established.

| Backend operation | Kubernetes meaning |
| --- | --- |
| `observe_health` / readiness | Bounded object/policy/node evidence checks; never boot a probe on every poll |
| `create` | POST exact persisted Pod intent; validate response and retain UID receipt |
| `start` | Wait for that same Pod/container to be Ready, with zero restarts; no second create |
| `inspect_machine` | Observe same identity without booting, repairing, adopting or replacing |
| `exec_stream` / `exec` | One WebSocket exec; observe raw output and terminal status, under one budget |
| `upload` / `download` | Qualified fixed helper, length-delimited binary protocol, scoped regular files |
| `delete` | Graceful DELETE with Pod UID precondition; inspect API and node evidence afterward |
| `stop`, retained start, optional families | Unsupported; never report a synthetic stopped machine |
| `list` / inspection | Bounded namespace inventory classified against durable assignments; labels only filter |

If `create` times out, do not POST again. A GET of the preallocated name can
reconcile the lost response only in the exclusive namespace, with matching
binding, nonce, complete immutable intent and no conflicting saved UID. Persist
the receipt before any further effects. A foreign/mutated match is a conflict,
not adoption. Absence after an ambiguous create is not enough to release the
reservation until node evidence rules out a sandbox left by that attempt.

`start` is only initial readiness. Pending, image-pull errors and scheduling
failure consume preparation budget and never authorize recreating the Pod.
Eviction, reboot, restart count changes, sandbox replacement or container-ID
changes invalidate the execution; this release never reschedules or retries it.

## Command protocol and uncertainty

Use the existing Mint/Mint.WebSocket building blocks for a dedicated Kubernetes
exec connection. Regular object requests may use Req with retries disabled for
mutations. Do not implement Kubernetes as a `SmolBox.Transport`: that interface
belongs to the SmolVM HTTP API. No new general-purpose Kubernetes dependency is
required for this small object surface.

Require `v5.channel.k8s.io`, binary frames, `tty=false`, separate stdout/stderr,
explicit container selection, and verified TLS. There is no SPDY fallback or
retry after upgrade/dispatch. Kubernetes' [versioned remotecommand constants](https://raw.githubusercontent.com/kubernetes/apimachinery/v0.35.0/pkg/util/remotecommand/constants.go)
define channel 0 stdin, 1 stdout, 2 stderr, 3 status, and 255 stream close. The
[client-go implementation](https://raw.githubusercontent.com/kubernetes/client-go/v0.35.0/tools/remotecommand/websocket.go)
provides a protocol reference, not code to invoke from Elixir.

Parse channel 3 as bounded structured Kubernetes Status. A Success status means
exit 0; a valid NonZeroExitCode cause carries the observed nonzero exit. A bare
WebSocket close, empty status, malformed status, proxy error, or successful HTTP
upgrade does not prove command exit. This follows the
[client-go status decoder](https://raw.githubusercontent.com/kubernetes/client-go/v0.35.0/tools/remotecommand/v4.go).
Keep status/control bytes out of workload stderr. Return `SmolBox.Result` with
`encoding: :bytes`, preserving nonzero exits as results and any qualified partial
result alongside completion errors. Do not reproduce the lab's kubectl stderr
diagnostic in SDK output.

Kubernetes exec has no public Pod-UID precondition in
[PodExecOptions](https://raw.githubusercontent.com/kubernetes/api/v0.35.0/core/v1/types.go).
Recheck the UID/container before and after exec, but acknowledge the race: those
checks are not an atomic fence. Exclusive namespace administration, never-reused
Pod names, one active controller and no replacement controller are required
first-release assumptions. Other principals able to recreate Pods in that
namespace violate the deployment contract; a post-exec mismatch cannot undo
effects. Labels, owner references, or a preflight GET do not solve that problem.

Do not put application argv/env or file paths in exec query parameters or
interpolate them into a shell. Invoke a fixed Python loader
(`python3 -I -S -u -c <fixed loader>`). Its query contains only infrastructure
code and the approved helper size/SHA-256. Send `SBP1`, a big-endian unsigned
32-bit source length and the exact approved helper source over channel 0. The
loader verifies the fixed size and digest before executing it from a Linux memfd
sealed against writes, growth and shrinkage. It does not evaluate user strings or
stage a writable script. The helper closes the source descriptor before application
exec. This keeps the upgraded request below the server request-line limit as
file support grows. Both fixed sources are compile-time package assets.

Next send `SBK1`, a big-endian unsigned 32-bit JSON-header length, the exact UTF-8
header, and only the declared raw upload bytes. The header includes version,
operation, absolute workspace path or command fields, declared byte count and
digest where applicable. Cap the header at the lower of 1 MiB and remaining
request budget before allocation; also bound depth, keys and decoded fields.
Check the complete source/control/data request size before upgrade. The helper
validates the command, changes directory, redirects application stdin to
`/dev/null`, acknowledges with `SBK1` followed by four zero bytes, and directly
execs the exact argv with the image environment plus explicit overrides.
Audit configuration must avoid recording exec payloads.

The controller keeps the producer open until completion. Neither EOF nor
stream-close delimits a request; this avoids the observed shim CloseIO/FIFO-drain
race. Internal helper input does not qualify user `Command.stdin`, which remains
rejected. The acknowledgement is stripped from command stdout. File responses
instead carry acknowledgement plus `SBF1`, a 32-bit header length (1–8192), exact
JSON metadata, then exactly the declared raw download bytes. Empty files have
size zero and the SHA-256 of empty bytes. Workload stdout/stderr remain unframed.
Invalid framing never falls back to shell/EOF behavior. See the
[implemented file protocol](kubernetes-file-protocol.md) for validation and limits.

`Runtime.Observation` already dispatches `exec_stream` for ordinary foreground
commands. Implement that operation even though this release has no public
interactive streaming API. Preserve per-stream ordering; do not promise a total
order between stdout and stderr. Bound decoded output, frame assembly, status,
queued callbacks and transport buffering. Handle fragmented/control frames and
backpressure without accumulating the entire stream before applying the cap.

Persist `:dispatching` before the exec upgrade. A socket timeout, cancellation,
controller failure, output overflow or lost status makes dispatch uncertain;
never replay it. Closing the socket does not kill the command. Cleanup deletes
the entire Pod and waits for positive termination evidence. If real exit was
observed, preserve it independently of output truncation or cleanup failure.

## File protocol

Use the same constant helper, with a different versioned operation in the
length-delimited control message. No `kubectl cp`, tar extraction, shell quoting,
host volume or shared controller filesystem is part of the contract.

Upload opens `/workspace` and walks path components with directory descriptors
and no-follow semantics. Reject absolute escape, `..`, symlinks, non-regular
targets and unexpected parent replacement. Write exactly the declared bytes to
a same-directory exclusive temporary file, verify size/digest, then rename
atomically. Short input never publishes the final name; interrupted operations
remain uncertain and the owned Pod is eventually deleted. Handle zero-length
files explicitly. A positive receipt includes actual size and digest; runtime
staging retains its existing read-back comparison.

Download opens a regular file through the same path policy, checks size against
the declared cap before sending data, and streams a bounded header plus exact
bytes and digest. Recheck file size/identity or fail if the file changes during
read; this is not a snapshot API. Bound actual received bytes independently of
the claimed header. Require the helper's real exit, validate the digest, and
publish to `ArtifactStore` only after validation. No diagnostics go on stdout.
Each operation shares one deadline across connection, transfer and verification.

The guest image, helper and sandbox are trusted for this functional file
contract. `/workspace` policy controls what SmolBox stages/collects; it is not
an isolation boundary against a malicious guest root process. Do not broaden
this preview into adversarial execution qualification.

## Resource and network qualification

Only approve a fixed profile with 2 vCPUs / 1,024 MiB guest RAM and disk fields
matching the pinned runtime's measured template sizes. Source defaults are
20/10 GiB, but record actual disks rather than asserting that source defaults
attest the release. No other CPU/memory/disk profile is silently rounded or
clamped. Reserve the profile plus conservative measured VMM/agent/rootfs-copy
overhead and at least one slot in the SmolBox store.
The current store resource map counts integer guest CPUs, not fractional
RuntimeClass CPU overhead; reduce advertised usable target capacity to leave
that headroom explicitly, rather than claiming the existing counter includes it.

Set container requests/limits and RuntimeClass overhead from an explicit
qualified accounting policy. Scheduler requests **plus** class overhead must
cover the full VM allocation and measured host overhead; do not double count or
mistake the upstream 160Mi class overhead for the 1-GiB guest. Also budget host
image cache, copied rootfs, disks and share growth. Kubernetes ephemeral-storage
accounting may not include shim-owned paths. The first lab's enclosing VM/disk
and one-slot limit provide a development bound; no Pod field alone proves a
host filesystem quota or VMM cgroup placement. Qualify guest limit enforcement
separately: the source contains fallback behavior when guest controllers are
unavailable. Metrics are diagnostic, not hard-limit evidence.

Profiles remain offline by default. The shim enables a NIC and joins a CNI
namespace, so this backend cannot implement offline by setting the Embedded
`network: false` flag. Administrators must install and qualify namespace-wide
default-deny ingress/egress before any execution. The controller cannot weaken
it. No DNS exception is added. Verify guest traffic traverses enforcement and
test DNS, public IPs, cluster services, node/host routes, link-local metadata,
and IPv6 (or an explicitly IPv4-only deployment). Kubernetes documents
[network-policy enforcement dependencies and node-traffic exceptions](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
Object existence is not evidence of effective offline behavior.

If the shim/CNI path cannot meet the existing offline contract, Phase 0 must
add and qualify a node-level restriction or obtain an upstream runtime change.
Until then there is no Kubernetes backend release. Do not reinterpret offline
as “no Service,” allow unrestricted guest networking, or add a permissive network
mode just to pass the first smoke.

Phase 0 has now demonstrated that NetworkPolicy alone leaves node-port and
node-originated ingress exceptions in this K3s lab. The qualified preview recipe
adds an administrator-owned bridge guard that drops all frames on verified
preview Pod bridge ports. The future NodeEvidence provider must verify fresh
guard membership and exact live rules before staging or dispatch. See the
[findings and constraints](kubernetes-backend-progress.md) and
[live evidence](../evidence/kubernetes-backend-phase0-2026-11-13.json). This does
not qualify other CNIs or replace the separate read-only cleanup provider.

## Cleanup, cancellation and recovery

The existing `Cleanup` implementation completes on `inspect_machine` not-found
and attempts stop/preservation for unknown executions. Both paths need explicit
Kubernetes handling. A deleted API object must not flow through the generic
not-found path and release capacity prematurely. With explicit zero retention,
unknown executions go directly to owned Pod deletion; `stop` is never invoked.

DELETE supplies `DeleteOptions.preconditions.uid` and a finite grace period.
Never force-delete, use collection deletion, remove arbitrary finalizers, or
delete the shared namespace. A conflict preserves the foreign object and the
reservation. Wait for original Pod absence and obtain a node cleanup proof.
Node deletion/disconnection, API not-found, Pod phase `Failed`, or a deletion
timestamp is insufficient proof of physical quiescence. Kubernetes itself
warns about force-deleted workloads continuing on their nodes in its
[Pod lifecycle documentation](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/).

Define `SmolBox.Kubernetes.NodeEvidence` as a required, bounded host extension
for this preview. It observes the **enrolled node**, its CRI sandbox mapping,
and pinned SmolVM state, and returns typed evidence tied to binding, Pod UID,
all observed sandbox IDs, VM directories, PID birth identities and an observation
epoch. It cannot create/stop/delete machines. Fail closed on incomplete mapping,
observer restart gaps, changed node boot ID, stale evidence or inaccessible state.
An empty global inventory or an arbitrary SSH exit code is not a proof.

The first provider is a manual-lab-only implementation using the existing SSH
access and fixed read-only node inspection program. Keep it under lab tooling,
not as a mandatory production SSH dependency. Extract the proven CRI/KVM/share
inspection logic from `scripts/kubernetes/smoke.py`; frame its bounded output
and validate every identity at the controller. Capture evidence before delete
and verify scoped absence afterward. A lost create response must first resolve
the original Pod/CRI mapping; if it cannot, leave cleanup unresolved. Do not
invent a proof for an attempt that was never observed.

Normal deployments will need a separately reviewed node-local authenticated
observer or equivalent upstream cleanup receipts. Building a privileged
DaemonSet/API for that purpose is outside this preview. **Without an approved
NodeEvidence provider, admission fails**; API-only physical cleanup is not
claimed. This requirement intentionally limits the first release to the lab.

Only after API absence and node proof are durably saved may cleanup become
`:complete` and its reservation be released. Keep command outcome, collection,
termination, API deletion and capacity release distinct. Missing evidence leaves
the reservation held and an actionable redacted failure. At most retry bounded
observation/UID deletion of the same assignment; never delete a replacement.
Per-name empty regular upstream lock files may be excluded exactly as in the
lab harness, but must never be unlinked; symlinks/nonempty files still count.
An operation durably proven never to have begun its create request can release
its reservation using not-dispatched evidence without a node proof. A lost
response or a controller crash after create intent is not that exception.

Recovery scans the complete authenticated assignment authority, including
tombstones, before enabling new dispatch. It does not just list labeled Pods.
Reconcile accepted/uncreated intents observationally; reconcile ambiguous POSTs
by exact intent; treat `:dispatching`/`:running` after owner loss as unknown;
resume safe collection only when a persisted real exit and the original live
container are still verified. Never re-exec to rediscover exit or output.
Delete/inspect already deleting originals under the saved UID and binding.
Unknown cluster, namespace, node, policy or runtime identity drains the target.
Node-failure recovery needs explicit future fencing/termination evidence.

Cancellation before any request is dispatched can finish with not-dispatched
evidence. Cancellation afterward stops observation and triggers deletion; only
node proof confirms termination. Controller restart cannot turn cancellation
into a second execution. A bounded cleanup attempt may end unresolved; a timer
or stopped outer VM does not manufacture successful cleanup evidence.

## RBAC, errors and diagnostics

Use a dedicated namespace and controller identity. Minimal workload Role:
`pods` create/get/list/delete and `pods/exec` get for WebSocket GET upgrade.
No Pod patch/update, deletecollection, logs, attach, port-forward, Secrets,
namespace creation, controllers, or policy writes. Polling avoids watch permission
in this release. Give read-only access to the named namespace/cluster anchor,
node and RuntimeClass through narrowly scoped bindings; administrators provision
them, plus get-only access to the named network policy. If an implementation uses
POST exec, grant create on pods/exec explicitly
after review rather than accidentally broadening all Pod permissions. See the
[Kubernetes RBAC reference](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

RBAC cannot restrict `pods/create` by a generated Pod's labels or make exec's
container parameters immutable. Namespace exclusivity and admission policy
must prevent foreign workloads, extra privileges and automatic mutation. The
first release is a host-controlled development environment, not shared-namespace
multi-tenancy. Node evidence credentials are separate from Pod credentials.

Map errors into existing redacted `SmolBox.Error` categories. Local invalid
config/unsupported feature is not-dispatched. A verified 401/403 rejection maps
to authentication with no application dispatch; a response lost after create
or exec remains uncertain. A UID conflict maps to identity_conflict. Bound
429/5xx read retries within the original deadline; never automatically retry an
ambiguous mutation or exec. Preserve real exit evidence even if later I/O fails.

Telemetry reports target ID, backend kind, operation, stage, bounded timing,
byte counts and redacted category/evidence. No bearer values, kubeconfig,
application argv/env, raw Kubernetes Status messages, input/output payloads,
or unrestricted event dumps. Inventory reports foreign/unmatched objects without
authorizing their deletion. List paging must follow bounded continuation tokens;
an expired/incomplete scan fails closed rather than reporting an empty domain.
ResourceVersion remains opaque; future watches must handle expired versions by
relisting, as described in [Kubernetes API concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/).

## Release gates and later releases

The preview requires all of the following, with exact source/runtime/image
hashes and positive cleanup evidence:

1. Fixed resource accounting and effective offline policy qualified on the real
   SmolVM/CNI path; release-versus-reference source differences are reviewed.
2. A usable approved Python image and byte-exact helper/exec/file implementation;
   silent exit 0, nonzero exit, binary output, empty files and corruption tested.
3. Durable Kubernetes assignment/receipt/cleanup proof support and compatible
   existing-record round trips across memory and reference durable stores.
4. Public create → execute → collect → delete success, failed command, failed
   transfer, cancellation, lost exec status, lost create response and controller
   restart without replay; failure cannot release capacity without proof.
5. Foreign/replaced Pod and recreated namespace/node remain untouched; no
   start/stop persistence or API-only quiescence is claimed.
6. Current HTTP/Embedded contract and compatibility suites remain passing.
   Lab/offline Kubernetes checks remain manual; no CI workflow change is needed.

## Roadmap to parity

After the preview, pursue the following capability milestones. Each needs a
separate detailed design and qualification gate; the preview's exclusions do not
remove these capabilities from the long-term goal.

| Milestone | Parity work |
| --- | --- |
| Production foundation | Authenticated node evidence, multi-node ownership/fencing, failure recovery, qualified resource sizing and operational measurements |
| Sources and connectivity | Private image credentials, broader image/artifact sources, qualified network allowlists, ports and associated admission policy |
| Retained machines and storage | Managed machine lifecycle and attached commands, persistent files, volumes and disk growth with equivalent ownership and reservation rules |
| Extended execution | Command stdin, guest users, broader file policies, startup workloads, background execution, logs and terminals |
| Saved state and publication | Exports, checkpoint capture/restore, branches and dependency/backing cleanup |

Retained lifecycle must preserve data and identity across stop/start; creating
another Pod alone does not satisfy that contract. Checkpoints and branches need
qualified runtime/storage support rather than assuming Kubernetes snapshots are
equivalent. The same rule applies to every parity feature: preserve its public
meaning before declaring support.

Maintain a versioned parity matrix with each capability marked implemented and
qualified, blocked by a named dependency, or planned. Cross-reference evidence
and remaining work. The completion gate for long-term parity is coverage of the
HTTP and Embedded domain capability surface with equivalent public behavior and
recovery guarantees, plus continued compatibility of those existing backends.
