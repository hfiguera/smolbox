# Node authority v1 frozen contracts

Status: Phase 0 contract checkpoint, November 14, 2026. The standalone provider
is not implemented, enabled or live-qualified at this checkpoint. This document
specializes the [specification](kubernetes-node-authority.md) for the
[implementation plan](kubernetes-node-authority-implementation-plan.md).

Normative data artifacts are
[`configuration.schema.json`](../../test/fixtures/kubernetes/node-authority-v1/configuration.schema.json),
[`protocol.schema.json`](../../test/fixtures/kubernetes/node-authority-v1/protocol.schema.json),
[`vectors.json`](../../test/fixtures/kubernetes/node-authority-v1/vectors.json), and
the executable pure-data checks in
[`authority_contract.py`](../../priv/kubernetes/node_authority/v1/authority_contract.py).
Fixtures contain synthetic identities only. Their hashes are not live approvals.

## Proof obligations and ownership

| Required fact | Source and retained witness | Node check / consumer | Rejection and required tests |
| --- | --- | --- | --- |
| Enrolled cluster/namespace/node/boot | Root configuration binding plus actual API object UIDs and kernel boot ID | Identity snapshot before/after observation; SDK binding equality | Different endpoint/node/boot/class; retain charge and block I/O |
| Approved runtime and program bytes | Pinned archive, rootfs manifest, verifier manifest and configuration digest | Hash exact assets/programs; inspect approved empty readiness markers only | Changed shim/kernel/rootfs/program/config; no new capture; original known cleanup remains independently observable |
| Complete runtime history | SQLite audit triggers in the VM write transaction; original DB device/inode/schema, event sequence, record preimages | Snapshot/replay and live-row equality | Omitted, reordered, changed or rolled-back prefix; no observation or cleanup proof |
| Durable original sandbox ownership | Root ledger UUID, watermark/hash and immutable sandbox-ID to Pod-UID map | Reconcile scoped CRI inventory with every journaled attempt | Unknown or remapped attempts, duplicate CRI IDs, unmapped historical attempt |
| Original VM process birth | Journaled PID/start ticks plus procfs executable/KVM descriptors and exact boot-config path | Capture and recapture same birth; typed `Observation` / receipt comparison | PID reuse, second boot or reinsertion, unowned KVM/boot process |
| Actual guest isolation | Approved guard program/template and fresh state, exact nftables rules, CRI/netns/bridge mapping | Read-only guard verification before capture; SDK dispatchability check | Permits, stale guard, changed rules, missing/aliased bridge mapping |
| Kubelet lifecycle quiescence | Original guaranteed-QoS Pod-cgroup device/inode/mount witness; unchanged K3s/containerd births | Lifecycle capture before readiness; absence under same lifecycle epoch during cleanup | Missing/replaced cgroup witness, daemon/mount/boot change; no inferred completion |
| Original Pod/CRI absence | Original saved UID/name, scoped API and CRI reads, repeated CRI/lifecycle check | Cleanup verifier; SDK attaches only its saved receipt | Replacement at same name, remaining original sandbox, inspection failure; API 404 alone is insufficient |
| Physical termination and path absence | All original process births, runtime rows, VM directories and shares tied to retained history | Explicit absence and unchanged audit snapshot | Live PID birth, extra attempt, leaked or symlinked owned path; never delete as repair |
| Fresh complete evidence | New request nonce; exact enrolled authority generation; node timestamp and journal prefix | Protocol validation and existing five-second dispatch freshness | Replayed/action-swapped response, future/stale time, incomplete history |
| Controller ownership | Existing same-host PID/birth/boot controller ledger and authenticated complete store scan | Unchanged `LabController`, startup fence and worker lease checks | Paused owner, unrecognized history, incomplete scan, lost lease; node response cannot grant takeover |
| Guarded capacity release | Persisted matching fresh version-3 proof under record/worker guards | Memory and reference PostgreSQL release validation | Failed/stale proof write or release, v1/v2 proof, changed receipt; keep reservation |

The producer must establish these facts physically. Structural projection and
codec tests alone prove neither complete history nor VM termination. Root and
the controller's approved code/credentials remain trusted; a coordinated rollback
of all node authority state is outside this provider's detection claim.

## Configuration schema and filesystem rules

The exact top-level fields are `version`, `binding`, `paths`, `guard`, and
`source_basis`. Unknown fields are rejected. `binding` is the full JSON projection
of the existing v1 binding, including its host-approved generation, fixed runtime
versions and asset/policy digests. The node compares that approved binding to live
identity; it does not implement a second, incompatible ETF generation algorithm.
The SDK must validate the binding before dispatching a callback.

All path values are absolute printable-ASCII POSIX paths of at most 4,096 bytes.
Reject NUL, control characters, noncanonical `.`/`..` components and writable
ancestors. Pin actual device/inode/file kind as appropriate; do not infer absence
from a permission or I/O failure. Application requests cannot change these paths.

| Path fields | Access and identity |
| --- | --- |
| `state_directory` | Root-owned 0700; ledger/enrollment/lock files only; no recursive deletion or reset through the endpoint |
| `database` | Qualified existing regular SQLite database; root-controlled ancestors; retain original device/inode; query-only during observation |
| `vm_root`, `share_root` | Qualified runtime-controlled directories; inspect scoped names and lstat entries; reject unexplained paths |
| `runtime_root`, `runtime_archive` | Approved runtime tree and checksum-pinned archive; administrator-owned; observation never installs/extracts them |
| `kubeconfig` | Root-owned regular 0600 file using the dedicated read-only API identity; never log contents; no inherited KUBECONFIG |
| `cri_socket` | Absolute enrolled K3s containerd socket; observations use explicit endpoint and read-only CLI operations |
| `k3s_executable`, `daemon_executable` | Explicit CLI and running multicall-image identities; resolve administrator-owned installation symlinks once and verify pinned image/process identities |
| `kubectl_executable`, `systemctl_executable`, `ip_executable`, `nft_executable`, `nsenter_executable` | Administrator-owned executables under verified non-writable ancestors; fixed argument templates only |
| `proc_root`, `cgroup_root`, `netns_root` | Qualified kernel mounts (`/proc`, `/sys/fs/cgroup`, `/run/netns` initially); verify mount/path identity; no alternate user-created proc/cgroup tree in production |
| `guard_program`, `guard_state` | Approved administrator-owned guard source and fresh root-owned state; observation never modifies guard rules or permits |

The `guard` object names the approved bridge table, marker, namespace-manager
label value and bridge. The source-basis object contains SHA-256 approvals for
the history and kubelet-lifecycle source reports. All program dependencies and
schema files must ship in the versioned bundle manifest. Limits are constants,
not configurable ways to enlarge history or observation budgets.

## Allowed observation commands

Every executable comes from the root configuration above, with a sanitized
environment. Every variable argument is a validated enrolled name, sandbox digest,
Pod UID-derived cgroup or qualified netns path; none is an arbitrary shell string.

| Operation | Fixed argument family |
| --- | --- |
| Kubernetes identity/inventory | `kubectl --kubeconfig=<approved> --request-timeout=<remaining> get` of the enrolled cluster anchor, namespace, node, RuntimeClass/policy and namespace Pods; `-o json`; original name `--ignore-not-found` for cleanup |
| CRI inventory | `k3s crictl --runtime-endpoint=unix://<approved socket> pods -o json` |
| CRI mapping | Same explicit endpoint, `inspectp <journaled sandbox digest>` |
| Daemon birth | `systemctl show k3s.service --property=MainPID --value`; procfs reads and approved-image hashing |
| Bridge state | `ip -j link show` and `nft -j list table bridge <approved table>` |
| Netns interface | `nsenter --net=<qualified netns> <approved ip> -j link show eth0` |

Runtime CLI machine inspection/start/stop/delete, Kubernetes mutation/exec,
shell commands, SQL writes and nftables mutation are absent from this endpoint.
The separate administrator enrollment path alone can install audit schema; the
separate approved offline guard owns network mutations.

## Privilege separation

| Actor | Permitted authority | Explicit boundary |
| --- | --- | --- |
| Node administrator | Provision bundle, principals, read-only API credentials and empty-baseline audit enrollment | Trusted setup only; no active-domain reset or automatic upgrade |
| Controller host | Approved SSH key/host pin, expected authority/program digests and existing API credentials | No node installation, arbitrary root command or new controller-owner grant |
| Evidence SSH principal | One literal protocol token and its framed stdin | Administrator-owned home/rc/key policy; no interactive shell, subsystem, PTY, forwarding, agent use or wildcard sudo |
| Privileged endpoint | Scoped procfs/CRI/API/filesystem observation; advance its evidence ledger | No workload mutation, enrollment writes, guard changes, secret responses or externally supplied roots |
| Node Kubernetes credential | Read/list namespace Pods; read enrolled namespace/anchor/node/class/policy and required version identity | No create/delete/exec, Secrets, broad namespace enumeration or mutation |
| Store adapter | Existing authenticated record/worker transactions, proof persistence and guarded release | Neither transport success nor node health can release usage |

The installed SSH/sudo configuration must be tested with real negative requests:
shell, SFTP/subsystem, PTY, local/remote forwarding, different command token,
additional command arguments, environment injection and arbitrary sudo. Fake
SSH fixtures prove framing/cancellation only, not effective server restrictions.

## Canonical data and wire contract

Canonical JSON recursively sorts object keys by their ASCII bytes, preserves
array order, uses no whitespace and standard JSON escaping, and encodes ASCII
bytes. Keys are nonempty printable ASCII of at most 128 characters. String values
are printable ASCII (empty strings allowed where a typed field allows them);
floats, NaN/Infinity, arbitrary objects and integers outside signed 64-bit range
are rejected. Version 1 uses no Unicode normalization or cross-language float
formatting. Maximum depth is 24 and object/list cardinality is at most 4,096,
with smaller typed bounds where specified. Duplicate keys are always invalid.

SHA-256 is applied to those exact canonical bytes, producing 64 lowercase hex
characters. The identity input is exactly `version: 1`, binding generation,
history UUID, enrollment nonce, verifier-manifest digest and configuration digest.
It contains no authority generation field, endpoint or credential. Configuration
digest covers the full configuration object; manifest digest covers its canonical
versioned file-hash object and excludes the manifest file itself.

The checked vector's standalone generation is
`f05eedbfa9a42c526baad2d1cdd7250947217b73c55016db0c75624adb2f5d6f`.
It is a synthetic fixture, not an enrollment approval. Its history UUID remains
separate. Elixir/Python canonicalization must agree on configuration, identity
and ready-receipt bytes before the provider can be enabled.

`SBA1` frames contain one 32-bit big-endian length and one JSON object. Body
length is 1–65,536; the eight framing bytes count against both callback grants.
Timeout is an integer in 1–30,000 ms; response allowance is 9–65,544 bytes. A
valid rejection may not fit a tiny allowance: in that case close the channel
without exceeding it. Connection/startup/parsing time is never refunded.

Action arguments and response value layouts are exact in the schema and executable
contract. A capture Pod UID is a canonical lowercase UUID, consistent with the
qualified kubelet lifecycle witness. A cleanup receipt must be typed-ready v1,
match binding/authority generation and carry its canonical receipt digest. It
cannot contain arbitrary data or an old lab epoch. Cleanup success contains v3
only and exactly the original processes/sandbox/path evidence. SDK type validation
and node-side physical verification remain mandatory after envelope validation.

Every well-formed rejection echoes request identity/nonce/action, sets `ok: false`,
`journal: null` and `value: null`, and returns one of `invalid_request`,
`identity_conflict`, `unavailable`, `expired`, or `output_limit`. Pre-identity
framing/schema failures close without evidence; a truncated/oversized/corrupt
input must not be reflected or printed as diagnostics on the framed channel.
Errors never embed remote stderr, paths, exception text, keys or tokens.

## Compatibility decision

`Shape.uid?` already accepts a lowercase 64-character digest as an opaque epoch.
The standalone provider alone projects its authority generation into that field.
The internal journal UUID and audit schema remain unchanged. No binding, receipt,
observation, proof or v54 envelope layout changes are necessary for this identity.

Tests must prove ready receipts reject changed epochs, mismatched old/new cleanup
proofs cannot release either domain, and cold v54 decoding preserves the digest.
An already-ready lab record cannot become a standalone record by receiving a
fresh capture. Client configuration and root enrollment both require a computed
generation; the provider rejects UUID-shaped legacy epoch approvals.

This decision does not enable active-domain handover, history compaction,
general anti-rollback storage, distributed fencing or node-reboot recovery. If
physical extraction cannot preserve the existing proof obligations, stop before
admission and design the required versioned successor rather than widening v3.
