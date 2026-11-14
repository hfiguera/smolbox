# Kubernetes development preview

SmolBox can run disposable foreground commands through one enrolled Linux
x86_64/K3s node using SmolVM. It uses the same `submit`, `fetch`, `await`, `cancel`
and ArtifactStore contracts as the HTTP and Embedded backends. Full domain
parity remains the [long-term goal](https://github.com/hfiguera/smolbox/blob/main/docs/design/kubernetes-backend-parity.md); this
preview supports the narrow policy below. Public qualification passed for this fixed lab setup; exact cases and limits are in
[implementation progress](https://github.com/hfiguera/smolbox/blob/main/docs/design/kubernetes-backend-progress.md).

## Supported policy

- One controller host, one durable store partition, one dedicated namespace,
  one enrolled node, one execution slot, one bare Pod/container per execution.
- K3s `v1.35.10+k3s1`, containerd `2.2.10-k3s1`, SmolVM `1.34.0`, and the exact
  approved archive/shim/rootfs/guard identities. Node reboot or daemon restart
  invalidates existing proof authority.
- Approved public OCI platform-manifest digest containing the qualified Python
  helper prerequisites. Tags, private registries and arbitrary images are unsupported.
- Offline two-vCPU/1-GiB guests; 20/10-GiB disk templates and 512-MiB declared
  host overhead. Capacity is admission accounting, not a VMM cgroup quota.
- Bounded foreground argv/environment, binary stdout/stderr, actual exit codes,
  files under `/workspace`, and declared ArtifactStore inputs/outputs.
- Explicit `retention_ms: 0`. There are no retained machines, attached commands,
  stdin, guest-user overrides, ports, volumes, workloads, terminals or checkpoints.

The host controller may run on macOS with Python 3, verified SSH access and an
HTTPS API tunnel. The MicroVM workloads run on Linux/KVM. Docker Desktop, kind
and k3d do not replace this runtime qualification.

## Administrator setup

Follow the [single-VM lab guide](https://github.com/hfiguera/smolbox/blob/main/docs/kubernetes-lab.md), including the four-hour outer
limit and shared lab lock. Install the approved runtime, dedicated RuntimeClass,
namespace and restricted service-account RBAC. NetworkPolicy alone failed the
live isolation control: the preview also requires the administrator-owned bridge
offline guard. Do not relax that guard to make application tests pass.

Install node history only against the verified empty baseline. Pin the reported
inspector/history source hashes and exact cluster anchor, namespace, node/boot,
RuntimeClass and policy identities in host configuration. Source/runtime pins
come from administrator qualification, not discovery or current mutable tags.
The fixed observer is read-only with respect to workload lifecycle. It preserves
transaction-backed sandbox history, original process births and cgroup lifecycle
witnesses. See [node evidence](https://github.com/hfiguera/smolbox/blob/main/docs/design/kubernetes-node-evidence.md) and
[cleanup authority](https://github.com/hfiguera/smolbox/blob/main/docs/design/kubernetes-cleanup-authority.md).

The application credential needs only the supplied restricted RBAC. Keep CA,
token and SSH material on the controller; execution records contain no tokens,
keys, endpoints or credential-provider contexts. Token resolution happens per
request under the operation deadline. Rotate a token file atomically and keep
its path stable. Rotate the approved CA/API connection only after validating the
same enrolled authority. Never bypass certificate validation.

Create separate existing 0700 local directories for controller metadata,
ArtifactStore data and manual reports. Use an absolute Python 3 executable.
Preserve the controller directory and durable-store encryption/fingerprint keys
across process restarts. An expired lease or stopped observer is not permission
for another controller; takeover requires positive death of the original BEAM
process on the same host. A missing/corrupt controller ledger cannot adopt an
existing assignment corpus.

## Configure and run

[The host settings example](../examples/kubernetes_host/settings.exs) constructs
`SmolBox.Kubernetes.Config` without network activity. Its JSON input supplies
these exact approved target fields:

```text
id, api_server, ca_file, cluster_id, cluster_anchor_uid, namespace, namespace_uid,
node_name, node_uid, node_boot_id, runtime_class, runtime_class_uid,
runtime_policy_digest, runtime_identity
```

It also supplies `image`, `token_file`, `ssh_host`, `inspector_sha256`,
`history_sha256`, `controller_directory`, `python_executable`, `artifact_root`,
`report_root`, and `fingerprint_key_file`. Paths are absolute; the fingerprint key
file contains 32 persistent random bytes. `runtime_identity` contains the exact
archive, shim, libkrun, kernel, rootfs and guard hashes plus qualified versions,
as shown in the checked-in evidence. Obtain live UIDs/boot and policy digest for
the enrolled lab; old evidence is not a portable cluster configuration.

From the project root, with the lab and HTTPS tunnel running:

```sh
export SMOLBOX_KUBERNETES_ENROLLMENT=/absolute/private/enrollment.json
mix run scripts/kubernetes/backend-smoke.exs \
  examples/kubernetes_host/settings.exs binary unique-binary-id
```

The script calls the public API, stages and reads back a binary input, executes
one command with exit 7, collects/verifies its binary output, waits for positive
cleanup and checks zero reserved slots. `silent`, `cancel` and `overflow` modes
exercise other outcomes. IDs must be unique for distinct executions. Run cases
serially. An `await` result is separate from cleanup and reservation release.
The `lost` and `reject` modes are intended for explicit loopback fault-proxy
campaigns; `reject` requires a failed preparation with positive original cleanup.
The TLS proxy keeps both legs verified and records only request counts/faults,
never credentials or application payloads.

Reports contain redacted outcomes; diagnostic record files may contain command
and output data. Keep the report directory private. Diagnostics are not a store
backup or permission to reconstruct missing authority.

The example uses Memory for development; process death loses its records. For
restart qualification, replace `store` with the reference PostgreSQL adapter and
set `mode: :durable`, apply the Kubernetes example migration, and preserve the
partition, encryption key, fingerprint key,
controller directory and ArtifactStore root. Run through the durable host Mix
project with its isolated database configured. There is no fallback to Memory.
The smoke script's `crash` mode waits at a running public-command boundary and
writes the owned BEAM PID; an explicit manual campaign may pause/kill that exact
process and invoke `resume` with the same settings and ID. `resume` submits no new
command. Never use a fresh execution ID to retry an uncertain command.

## Cleanup and recovery

Cancellation requests disposal; it does not claim that the command stopped.
Lost create responses reconcile the saved intent without another POST. Lost exec
status, controller death after dispatch, cancellation and output overflow can
leave the command outcome unknown. The SDK never replays that application work.
A real durable exit remains separate from collection or cleanup failures.

Cleanup deletes only the saved original Pod UID. API absence alone cannot release
capacity. The version-3 node proof requires original-UID API/CRI absence, complete
unchanged sandbox history, original VM process termination and scoped path/SDK
absence, plus the persisted original kubelet lifecycle witness and unchanged
daemon incarnations. The store saves the proof before guarded release. Historical
versions 1/2 decode but cannot release capacity.

A cleanup deadline limits mutation. After it expires, bounded read-only proof
observations may establish that the original deletion finished; they do not reset
the deadline or issue another application command. Capacity remains charged until
positive proof. A transient `cleanup: :failed` can therefore later become complete.
If proof remains unavailable, inspect the record, `SmolBox.audit_worker/3` and
administrator node evidence. Preserve original UIDs, receipts, ledgers and errors.
Do not sweep by labels, force release, reset enrollment, delete audit history or
silently adopt a replacement Pod. A node reboot, daemon restart or lost mapping
requires investigation; this preview does not promise automatic repair.

## Manual validation

```sh
mix test --warnings-as-errors
python3 -B -m unittest discover -s scripts/kubernetes -p 'test_*.py'
mix test test/unit/kubernetes_recovery_test.exs \
  test/unit/kubernetes_runtime_lifecycle_test.exs
```

Run the reference PostgreSQL Kubernetes contracts and explicit live public smoke
separately. These checks are manual. No Kubernetes cluster, SSH access or new lab
job is added to CI. Production Kubernetes support requires a separately reviewed
node-evidence and controller-fencing mechanism.
