# Single-node Kubernetes development lab

This opt-in maintainer environment runs a real K3s node and SmolVM containerd
runtime inside a separate disposable QEMU/KVM guest on the authorized `ssh linux`
host. It establishes the upstream create → execute → collect → delete path.
It does **not** implement or qualify a SmolBox Kubernetes backend, persistent
volumes, network policy, node-failure recovery, or multi-node scheduling.

## Topology and limits

```text
Mac: edit source, run offline harness tests, open SSH connections
  ssh linux (pop-os): existing host and existing worker stay separate
    user service: smolbox-kubernetes-lab.service
      Ubuntu guest: smolbox-k3s, 4 vCPU, 8 GiB RAM, 40 GiB disk
        K3s + containerd + SmolVM RuntimeClass
          one smoke Pod sandbox → one real nested microVM
```

The host service limits the outer VM to 400% CPU bandwidth, 12 GiB RAM, no
cgroup swap, 256 tasks, and four hours per start. It is not enabled at host boot.
Its disk and private SSH identity live under `/var/lib/smolbox-lab/kubernetes`,
inside the existing bounded lab filesystem. It shares `/var/lib/smolbox-lab/vm.lock`
with the older lab, so both cannot boot concurrently. Existing baseline images,
host containerd configuration, and host SmolVM machines are not modified.

Only the node's SSH and Kubernetes API are forwarded, on physical-host loopback
ports `22470` and `16443`. The outer VM has outbound networking for package and
image downloads. This environment is not an adversarial isolation campaign.

[`pins.json`](../scripts/kubernetes/pins.json) records the dated Ubuntu image,
K3s binary, complete SmolVM distribution, and amd64 workload image. Downloaded
artifacts are checked against their exact SHA-256 pins. Guest apt packages are
installed from Ubuntu repositories; their versions must be recorded with live
evidence. The recipe is repeatable, not a byte-reproducible OS build.

## Prepare and start

The authorized host must already have QEMU, `qemu-img`, `cloud-localds`, SSH,
curl, jq, a lingering systemd user manager with CPU/memory/task controllers,
KVM access, nested virtualization, and the existing lab filesystem. Preparation
reuses its checksum-verified Ubuntu cloud image and requires over 50 GiB free
inside that filesystem on first creation. No host-wide sudo installation is needed.

From the project checkout on the Mac:

```sh
rsync -a --exclude __pycache__ scripts/kubernetes/ linux:smolbox-kubernetes-lab/
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh prepare'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh start'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh install'
```

The install action waits for guest SSH, transfers the verified downloads, then
provisions **inside the new guest** using its lab-only sudo account. It installs
K3s as a guest service and extends K3s's base containerd v3 configuration with
`io.containerd.smolvm.v2`. The unchanged upstream shim and full runtime assets
remain together under `/opt/smolvm-1.34.0-linux-x86_64`. The service supplies
explicit rootfs/library paths and dedicated XDG data/cache/config roots.
Disk templates are expanded sparsely before a Pod's readiness deadline starts.

The node runs ordinary system Pods using the default runtime. Workloads opt into
SmolVM using `runtimeClassName: smolvm`. The upstream RuntimeClass declares
250m CPU / 160Mi memory overhead and selects `smolvm-runtime=true` nodes.
Traefik, ServiceLB, and local-path storage are disabled for this first smoke lab.

Preparation is non-destructive and rejects a changed pin set or an unrelated
existing directory. Subsequent starts reuse this development disk. Never turn
a disk used for hostile tests into a trusted development baseline.

## Run the smoke test

```sh
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh smoke'
```

The check runs as root **only inside `smolbox-k3s`**, using the guest's private
admin kubeconfig. It creates a random namespace and a digest-pinned BusyBox Pod
with `restartPolicy: Never` and no mounted service-account token. It then:

1. Records the exact Pod UID, container ID, and CRI sandbox ID.
2. Associates that sandbox with its SmolVM directory and original boot process.
3. Requires real KVM VM/vCPU descriptors and a guest kernel distinct from the node.
4. Stages 4,352 binary bytes through length-delimited stdin, verifies separate stdout/stderr and
   workload exit 7, and collects the file back byte-for-byte with a SHA-256 digest.
5. Confirms the Pod/container incarnation did not change during execution.
6. Deletes owned resources with atomic Kubernetes UID preconditions and a grace
   period, then requires original KVM process collection and machine-record,
   VM-directory, and sandbox-share inventories to return to their baseline.

Cleanup also runs after a failed assertion. Cleanup failure makes the entire
test fail; accepting a Kubernetes deletion request is insufficient. It never
force-deletes resources or removes arbitrary machine names. The JSON report
contains test identities and dummy data, not kubeconfig credentials or tokens.
Each attempt has a unique report filename on guest and host. Host-side
`smoke.json` points to the most recently collected report. Upstream retains empty
per-name `.fork-operation.lock` files after deletion. Only exact, empty, regular
lock files are exempt from the VM-directory baseline comparison; they are never
unlinked by the harness. Nonempty files and symlinks still fail the comparison.

The first live run exposed an upstream stdin-close race: sending data and EOF
together could produce an empty guest file. The smoke keeps the producer open
until a command that reads an exact byte count exits. It still verifies raw
binary input and collection, but **does not qualify EOF-driven stdin**. Preserve
this limitation when designing the future backend's input protocol.

To update the harness after editing it, repeat rsync and use `lab.sh sync`.
This does not reinstall K3s or restart workloads. To inspect or stop the environment:

```sh
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh status'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh ssh sudo kubectl get pods -A'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh stop'
```

The stop action requests guest shutdown, waits up to twenty seconds, then stops
only the owned outer service if it has not exited. The service's four-hour
deadline stops the outer VM independently of SSH.
Start it again with `lab.sh start`; the guest's K3s service starts automatically.
Stopping the outer VM is not evidence that a smoke test passed or cleaned up.

For API access from the Mac, forward the host's loopback API port with
`ssh -N -L 16443:127.0.0.1:16443 linux`. Use a private kubeconfig obtained from
this guest, adjust its server port to `16443`, and retain TLS verification.
Do not put the kubeconfig in Git or expose the API on a wildcard address.

## Offline checks and evidence

```sh
python3 -m unittest discover -s scripts/kubernetes -p 'test_*.py'
for script in scripts/kubernetes/*.sh; do bash -n "$script"; done
```

Run these checks manually when changing the lab scripts; they need no SSH, KVM,
or Kubernetes. The tests require corrupted binary output, synthetic exit 255,
missing KVM evidence, and failed cleanup to fail the evidence gate. Neither these
offline checks nor the live smoke runs in CI. Live VM checks are explicit
maintainer actions on `ssh linux`.

The SmolVM archive pin identifies this upstream Kubernetes distribution. It
does not replace or inherit the HTTP/Embedded Port qualification archive pins.

Live evidence must record the tested source revision, exact runtime/shim and
image identities, node/guest kernels, KVM descriptors, execution result, and
cleanup verification. This smoke provides no evidence for deferred backend
features or failure-recovery guarantees.

The [2026-11-13 live report](evidence/kubernetes-lab-2026-11-13.json) records a
passing run after VM restart and reprovisioning, including source file hashes,
4,352 collected bytes, exit 7, and empty post-cleanup runtime inventories.

The proposed [Kubernetes backend design](design/kubernetes-backend.md) and
[implementation plan](design/kubernetes-backend-implementation-plan.md) build on
this lab. They describe future work; the current smoke exercises upstream runtime
operations directly rather than a SmolBox Kubernetes backend.

## Preview runtime qualification

The manual Phase 0 probes add a dedicated `smolbox-preview` namespace,
default-deny policy, and RuntimeClass with 512Mi memory overhead. Unlike the
original upstream smoke, this accounts for the full 1-GiB VM plus 512Mi declared
host overhead. The preview remains limited to one slot and the enclosing VM.

NetworkPolicy alone failed controlled node-port and node-to-Pod tests. Preview
setup therefore also installs an administrator-only **inside-guest** bridge guard:
it maps preview Pods through CRI to CNI bridge ports and drops all frames on
those ports. No physical-host firewall or other namespaces' ports are changed.
The guard is a separate guest service; ordinary application credentials cannot
change it. See [progress and constraints](design/kubernetes-backend-progress.md).

```sh
rsync -a --exclude __pycache__ scripts/kubernetes/ linux:smolbox-kubernetes-lab/
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh install-preview'
ssh linux 'bash ~/smolbox-kubernetes-lab/lab.sh qualify'
```

`qualify` checks pinned archive/installed runtime/rootfs identity, fixed guest and
scheduler resources, Python prerequisites, real WebSocket v5 binary channels and
exits, controlled IPv4/IPv6 and inbound network isolation, and positive VM cleanup.
It briefly permits only its marked canary Pod to establish working network
controls, restores full isolation, and fails if any probe remains reachable.
Only root inside the disposable node can grant the expiring qualification permit.

Unique reports and the latest `qualify.json` are collected under the existing
host lab directory. The [Phase 0 report](evidence/kubernetes-backend-phase0-2026-11-13.json)
records the failed NetworkPolicy-only control and the passing guarded run.
These probes and the expanded 21-test Python suite remain manual. They qualify
the lab's runtime recipe; a SmolBox Kubernetes backend is not implemented yet.


## Restricted object API credentials (manual)

Phase 3 qualifies the assigned backend object port; it does not enable public
execution or store cleanup release. Follow the
[phase status](design/kubernetes-backend-progress.md) and
[exact evidence](evidence/kubernetes-backend-phase3-2026-11-13.json).

Copy the current scripts to the physical host as above, then run
`~/smolbox-kubernetes-lab/lab.sh sync`. An administrator inside the **disposable
guest** can apply `/home/lab/smolbox-kubernetes/runtime-rbac.yaml` with
`sudo k3s kubectl apply -f /home/lab/smolbox-kubernetes/runtime-rbac.yaml`.
The file is an explicit lab example tied to namespace `smolbox-preview`, node
`smolbox-k3s` and RuntimeClass `smolbox-preview`; review these identities before
using another deployment. Script sync copies the file but never applies it.

The `smolbox-controller` service account can create/get/list/delete Pods only in
that namespace and GET `pods/exec` for WebSocket v5. It can read only the named
namespace/anchor/node/class/offline policy and API version. It cannot write
policies, nodes, classes, namespaces, Secrets or controllers. Kubernetes RBAC
cannot constrain Pod template contents; this credential belongs only to the
trusted controller, whose assigned backend validates the immutable intent.

Issue a short-lived token manually with
`sudo k3s kubectl -n smolbox-preview create token smolbox-controller --duration=2h`.
Write its output directly to a private host token file; do not paste it into
source, command arguments or evidence. Export only the public server CA for
verified TLS. `SmolBox.Kubernetes.Config` accepts this token file or a bounded
host callback. Keep API port forwarding on loopback with an explicit trusted CA
and verified hostname; the library reads no admin kubeconfig and runs no auth
plugin. Token rotation does not change the enrolled domain.

The component qualification persisted original intent/UID before readiness and
used the restricted token for create/readiness/UID-delete. Root SSH inspection
inside the guest observed actual KVM births, SQLite records and scoped disk/share
paths. API absence alone did not establish cleanup. A production node observer,
continuous history and the public managed smoke remain Phase 6–7 work. Do not
promote the manual inspection report into a fabricated store cleanup proof.
