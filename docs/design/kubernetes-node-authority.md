# Kubernetes single-node authority

Status: implementation specification, November 14, 2026. The standalone provider is
implemented through Phase 4 but not qualified or enabled for execution. Delivery branch:
`feature/kubernetes-node-authority`.

Phase 0 contracts are frozen in the [contract checkpoint](kubernetes-node-authority-contract.md),
with schemas/vectors and Python/Elixir compatibility checks. Standalone extraction
and administrator installation have passed their fixture gates; protocol/SDK
and real pre-enrollment access checks have passed Phase 3. Phase 4 public runtime,
Memory/PostgreSQL and compatibility gates pass against simulated node evidence.
Manual live qualification remains Phase 5; see the
[implementation progress](kubernetes-node-authority-progress.md).

Follow the [implementation plan](kubernetes-node-authority-implementation-plan.md),
[backend parity matrix](kubernetes-backend-parity.md), and existing
[node evidence](kubernetes-node-evidence.md) and
[cleanup authority](kubernetes-cleanup-authority.md) contracts.

## Outcome and branch boundary

Deliver an explicitly configured, administrator-installed node authority that
can support the existing disposable execution contract on one qualified Linux
x86_64/K3s node without the `lab.sh` wrapper or an outer-VM command path. The
controller remains usable from macOS. Public execution APIs stay unchanged.

This is the first slice of the production-foundation milestone. Its claim is a
reviewed standalone provider for the qualified single-node setup. A new transport
does not qualify general production Kubernetes, new runtime versions or different
physical cleanup semantics. Full HTTP/Embedded parity remains the long-term goal.

| Included here | Separate delivery |
| --- | --- |
| Versioned authority protocol and explicit host approvals | Multi-node scheduling and relocation |
| Standalone verifier, restricted node access, administrator enrollment | Distributed controller fencing and cross-host takeover |
| Original-incarnation capture and version-3 physical cleanup | Recovery through node reboot, daemon restart or lost history |
| Packaging, installation, bounded observation and diagnostics | History compaction and active-domain authority upgrades |
| Current disposable public path and manual qualification | Retention, new sources, networking, storage and extended execution |

Keep the fixed source/profile, offline policy, one slot and zero retention of the
merged preview. Keep `LabNodeEvidence` available explicitly. Selecting the new
provider must never fall back to the lab provider, an unchecked SSH command or
API-only cleanup.

## Existing implementation and the gap

`NodeEvidence` already defines bounded `check/3`, `capture/4`, and `cleanup/4`
callbacks. `Guard` and `KubernetesIO` consume typed observations/proofs, while the
store validates and persists proof before releasing reservations. Recovery runs
in a separate supervised task, with health probes renewing the worker lease.

`LabNodeEvidence.Transport` currently invokes a constant command through
`~/smolbox-kubernetes-lab/lab.sh ssh`. The inspector and installer also embed the
lab hostname, namespace, paths and nested-VM assumptions. Its transitive program
set includes qualification and smoke utilities. Generalizing a host string alone
would leave those operational and trust dependencies in place.

The current `LabController.Context` is also required by config validation and
recovery. This branch keeps that same-host PID/birth/boot guard intact, including
its existing name and context shape. The next controller-fencing design must
replace that integration deliberately; this provider adds no controller ownership
authority and no permission to run two controllers against one domain.

## Decisions

1. Install a fixed, short-lived evidence endpoint directly on the enrolled node.
   Use constrained SSH as the first transport; introduce no inbound HTTP service,
   DaemonSet, operator or public node-agent API in this branch.
2. Separate the verifier core from CLI/transport and lab provisioning. Reuse the
   reviewed proof algorithms through an explicit extraction and source comparison.
3. Load one root-owned enrollment configuration. Request bodies cannot select
   filesystem paths, commands, executables, namespaces or another node.
4. Require a fresh authority generation for the standalone provider. Do not adopt
   active lab receipts or rewrite historical proof records.
5. Preserve `Binding` v1, `Observation` v1, `CleanupProof` v3 and selective codec
   v54 if their existing opaque epoch field can carry the identity specified
   below. A discovered need for more durable fields requires a reviewed versioned
   migration before implementation continues; never hide them in unvalidated maps.
6. Keep journal bounds and fail-closed behavior. This branch has no automatic
   history pruning, reset, live verifier upgrade or forced reservation release.

## Trust and access boundary

The node administrator, controller host, approved verifier programs, Kubernetes
control plane and pinned runtime are trusted. The endpoint must defend against
untrusted execution input, malformed requests, stale/replayed responses, endpoint
misrouting and interruption. It does not protect against a malicious node root or
a controller host that can replace its own approved code and credentials.

The administrator provisions a dedicated evidence SSH principal/key and pins its
host identity. Its home, startup files and authorized-key policy must be
administrator-controlled and unavailable for writes by that principal.
Use a server-side forced command with forwarding, PTY and user rc
execution disabled. OpenSSH documents that a forced command alone still permits
forwarding unless separately restricted; use its `restrict` controls and verify
the effective configuration on the installed server version.
[OpenSSH authorization options](https://man.openbsd.org/sshd.8#AUTHORIZED_KEYS_FILE_FORMAT)

The forced entrypoint accepts only the literal command token
`smolbox-node-authority-v1`, then launches one fixed root-owned program with a
fixed configuration path. If privilege elevation is necessary, the administrator
grants only that exact entrypoint and argument vector. No wildcard sudo rule,
client-supplied interpreter/script path, shell evaluation of `SSH_ORIGINAL_COMMAND`,
or writable privileged program/configuration directory is permitted.

The SDK spawns SSH with an argument vector, no PTY, noninteractive public-key
authentication, explicit identity/known-hosts files, strict host-key checking,
no agent/X11/port forwarding, and no multiplexed session reuse. Use `-F /dev/null`
so implicit SSH config cannot introduce a proxy command or different identity.
Connection host, port and user are explicit validated fields. A separately
administrator-operated tunnel may expose the node's SSH endpoint to the Mac;
the node host key and returned enrollment identity still have to match.

The node holds a separate read-only Kubernetes credential scoped to the required
namespace/node/RuntimeClass/cluster-anchor and policy observations. It needs no
Pod create/delete/exec, Secrets access or runtime mutation authority. Root access
to procfs, CRI observation and the audit/ledger files remains part of the reviewed
node-administrator trust boundary. Root read access is not a sandbox guarantee.

## Installation and immutable enrollment

Proposed paths below are installation defaults, not application request fields:

| Asset | Default / rule |
| --- | --- |
| Program bundle | `/usr/local/lib/smolbox-node-authority/v1/`, root-owned and immutable during enrollment |
| Fixed entrypoint | `/usr/local/libexec/smolbox-node-authority` |
| Configuration | `/etc/smolbox-node-authority/enrollment.json`, root-owned, mode 0600 |
| Evidence state | `/var/lib/smolbox-node-authority/`, root-owned, mode 0700 |
| Logs | Administrator journal, bounded structured events; no payloads or credentials |

An offline-buildable bundle contains every transitive verifier dependency and a
manifest with per-file hashes. It must not import from a controller checkout,
`smoke.py`, a lab home directory or an unapproved Python import search path.

The administrator supplies an exact validated configuration: binding generation
and enrolled object identities; runtime/source-basis and verifier manifest hashes;
absolute runtime database, VM/share roots and observation executable paths;
read-only Kubernetes/CRI observation configuration; cgroup/lifecycle assumptions;
and the approved offline-guard identity, rules template and state path. Paths
must be non-ambiguous, root-controlled and covered by the configuration digest.
Keep the currently qualified K3s/containerd/SmolVM versions and resource shape.

Enrollment requires positive empty API, CRI, runtime-row, creation-reservation,
VM-process and scoped path inventories under the existing transaction/lock
ordering. Establish the audit triggers, database identity, lifecycle baselines and
root-owned ledger before enabling the endpoint. Unknown runtime resources reject
enrollment. Installer/schema writes are separate from observation callbacks.
Publish active enrollment and its approval descriptor only after the complete
baseline and installed files/state are durably committed. A partial installation
must never answer as an enrolled authority.

An identical repeated install validates existing files/enrollment and makes no
changes. A partial install, changed program/configuration, missing ledger or
existing different enrollment stops with an administrator-visible diagnostic.
There is no remote `install`, `reset`, `repair`, `upgrade`, `delete` or `release`
request. Observation can advance only its own verified root-owned evidence ledger.

The live campaign must use a new isolated domain and fresh, positively empty
authority baseline. Prefer a fresh disposable guest. Existing lab journals,
controller ledgers, store bindings and tombstones remain preserved. A new worker
name alone does not make an occupied node or existing audit schema reusable.

## Authority identity and durable compatibility

Keep two identities distinct:

- `history_epoch`: the existing journal's UUID; its audit schema and continuity
  checks retain their existing meaning.
- `authority_generation`: SHA-256 of canonical, versioned JSON containing the
  binding generation, history epoch, enrollment nonce, verifier manifest digest
  and enrollment configuration digest. Publish the exact canonical encoding and
  digest test vector in the protocol fixtures before implementation.

The administrator records the generated authority generation and verifier
manifest digest in the SDK provider configuration. The endpoint checks them
against its root-owned enrollment on every request. Responses echo them and the
binding generation. For this provider, typed `Observation.observer_epoch` and
`CleanupProof.observer_epoch` equal the authority generation. The internal audit
UUID remains unchanged and is never replaced with that digest.

This uses the existing opaque epoch field without changing record shapes.
Configuration/program changes require a different generation and cannot validate
old receipts. The compatibility gate must prove that existing constructors,
receipt comparisons, Memory/PostgreSQL validators and cold codecs enforce this
mapping. It must also reject choosing a lab epoch as a standalone generation.

The provider's endpoint, user, credential paths, live handles and node Kubernetes
credentials stay outside durable execution records. Approvals needed to interpret
the evidence are bound by the saved generation, rather than by a mutable endpoint.
Keeping the same endpoint or rotating a transport key does not change an epoch.
Changing its enrolled authority does.

The first release supports new domains only. Existing lab receipts keep their
original provider and epoch; cross-provider continuation of a charged execution
is unsupported. Preserve old readers, fixtures and source evidence. Do not
automatically rotate epochs, migrate receipts or reinterpret historical v1/v2
cleanup proofs as release authority.

## Protocol v1

Use a distinct frame magic, `SBA1`, followed by a big-endian unsigned 32-bit JSON
byte length and exactly that body. One SSH process owns one request and response.
No banners, diagnostics, extra frames, compression or trailing bytes are accepted.

Requests contain exactly `version`, `action`, `nonce`, `binding_generation`,
`authority_generation`, `verifier_manifest_sha256`, `timeout_ms`, `max_response_bytes`
and the action-specific `arguments` object. `version` is 1; `nonce` is 32 random
bytes encoded as lowercase hex. Actions and arguments are:

| Action | Arguments | Successful typed value |
| --- | --- | --- |
| `check` | Empty object | `complete_history`, `idle`, `observer_epoch` |
| `capture` | Exact original `pod_uid` | Current `Observation` fields |
| `cleanup` | Exact saved ready receipt and its canonical SHA-256 | `CleanupProof` fields excluding the receipt |

Successful responses contain exactly the version/action/nonce and three
generation/manifest identity fields above, `ok`, `journal`, `value`, and `error`.
`journal` contains the history UUID, verified watermark and prefix hash. On
success `ok` is true and `error` is null; a rejected request returns no evidence
value and only an approved bounded error code. Define exact rejection envelopes
and field bounds in fixtures; unknown versions, keys, actions and duplicate JSON
keys fail closed on both sides. Do not intern response strings as arbitrary atoms.

Validate nonce, action, identities, canonical receipt digest and typed result
before attaching the original receipt to a cleanup proof. Never accept a server's
replacement receipt. Check responses against the administrator's approvals and
the request, not another field in the same response. Recorded responses from a
prior call, action, receipt, target or epoch must be rejected.

The JSON body limit is 65,536 bytes. Both frame headers count against the caller's
granted request/response budgets. Enforce the smaller of the protocol limit and
that grant before allocation/read/write. The server starts a 30-second monotonic
deadline before reading the first header byte. A validated request tightens it
to the earlier of that deadline and entry time plus the supplied caller timeout;
parsing time is never refunded. Locks, child processes, ledger writes and output
share it. Client and server do not compare absolute
monotonic timestamps from different hosts. Existing operation accounting and
callback grants remain authoritative and are never enlarged by this provider.

Malformed or disconnected input, timeout and caller death close the channel and
terminate only the endpoint's owned read-only observation children. They cannot
kill a VM or reset its evidence. No retry resets the original operation budget.
Observation retries may obtain a new nonce; they never replay application work.

Retain the current observation freshness rules, including rejection of future
timestamps and observations older than five seconds at dispatch. Clock skew or
latency that prevents satisfying those checks blocks application I/O; do not
rewrite node timestamps or expand freshness as a transport workaround.

## Evidence and cleanup invariants

The extraction must preserve all existing proof obligations:

1. Audit events commit in the same transaction as runtime row changes. Verify
   database device/inode, exact schema, contiguous sequence and replayed live rows.
2. Retain immutable sandbox-ID to original Pod-UID mappings, including deleted
   attempts. Missing mappings and unexplained resources make history incomplete.
3. Capture the original VM executable, PID birth, KVM descriptors, scoped paths,
   container/image identity, bridge mapping and effective offline guard.
4. Persist the original kubelet cgroup witness and unchanged node boot, cgroup
   mount and K3s/containerd process births required by version 3.
5. Cleanup requires original API/CRI absence, termination of all captured process
   births, scoped runtime/path/share absence and lifecycle quiescence. Never
   substitute a successful SSH command, current Pod name or API 404 for that proof.
6. Persist the matching fresh proof before guarded reservation release. Preserve
   real command exits and collection results when cleanup fails.

The cgroup witness establishes kubelet lifecycle progress only. This branch adds
no VMM CPU/memory confinement claim and preserves the existing fixed resource
accounting and enclosing-VM qualification assumptions.

Use consistent before/after snapshots and a single bounded evidence lock. Keep
the existing limits of 4,096 audit events, 128 KiB per history record, 64 MiB of
history and the existing bounded runtime/process inventories. Exhaustion makes
the authority unavailable. No truncation, rotation or limit expansion is part of
this branch. Compaction requires a separate durable continuity design.

Verify prefix continuity against the independent retained ledger. This does not
prove detection of a coordinated rollback of every authority file and runtime
database. Node storage rollback is unsupported; administrator restore requires
preserving unresolved authority and a separately reviewed recovery procedure.
Do not claim a remote freshness nonce solves persistent-history rollback.

The verifier may observe cleanup despite a failed isolation/asset health check
when the original physical authority remains known, as the existing cleanup path
allows. Node reboot, daemon restart, lost ledger or lifecycle witness still
invalidates proof and retains capacity. The endpoint never repairs such failures.

## Runtime integration and controller ownership

SDK API: `SmolBox.Kubernetes.NodeAuthority.new/1`, returning an explicitly
validated callback context for `node_evidence: {NodeAuthority, context}`. The
context holds connection fields and expected generation/manifest approvals, with
redacted Inspect. Construction performs no SSH, credential lookup or node writes.

Reuse bounded Port transport and typed projection helpers where their contracts
match; separate generic code from lab-specific names without changing the lab
protocol. Public `submit/fetch/await/cancel`, artifact handling and backend policy
remain unchanged. Introduce no new capability flags for later parity features.

Keep complete authenticated startup scans, frozen admission, supervised recovery,
worker-lease renewal, UID-bound deletion and store release guards. In particular,
the new endpoint cannot grant controller ownership. Same-host original-process
death remains required by `LabController`; no cross-host takeover is added here.

Kubernetes documents Leases as heartbeat and leader-election coordination. The
future fencing branch must separately prove prevention of work by an old owner
and termination/cleanup authority; this design assigns neither meaning to Lease
expiry. [Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/)

## Qualification and completion

Complete the phase gates in the [plan](kubernetes-node-authority-implementation-plan.md).
The merge gate requires explicit protocol fixtures, module/package compatibility,
malformed/replay/timeout/caller-loss tests, authority mismatch controls, public
Memory and PostgreSQL execution/recovery campaigns, and a manual restricted-access
installation on the real single-node SmolVM setup.

Record exact program/configuration/runtime identities, initial and final journal
anchors, stage outcomes, one-create/one-application-exec traces, original-UID
deletion and persisted proof before zero reserved usage. Record failed controls
as well as successes. Source or packaging checks alone cannot qualify the new
provider. Never describe the existing lab evidence as evidence for this provider.

Ordinary Elixir fixtures can run through existing project checks. Python, SSH,
cluster provisioning and live campaigns remain manual. This branch changes no
CI workflow and performs no installation merely by loading the SDK.
