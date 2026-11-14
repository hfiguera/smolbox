# Standalone node authority administrator tooling

This tooling is manual. It does not provision a node, install an SSH key, change
sshd/sudo configuration, mutate an offline guard, replace the node runtime, reset
history or upgrade an existing domain. Follow the
[design](../../../docs/design/kubernetes-node-authority.md),
[contracts](../../../docs/design/kubernetes-node-authority-contract.md) and
[implementation progress](../../../docs/design/kubernetes-node-authority-progress.md).
The provider is not enabled or live-qualified by building or installing a bundle.

## Build and custody

From a reviewed checkout, with Python's standard library only:

```sh
python3 -B scripts/kubernetes/node-authority/bundle.py \
  --output /absolute/path/smolbox-node-authority-v1.tar.gz
```

The output must not already exist. The command prints an archive SHA-256, verifier
manifest SHA-256 and program hashes. Repeating the build with identical sources
produces identical bytes. The archive contains the complete verifier, fixed
entrypoints, installer, configuration schema, access-policy example and two
manifests. It contains no keys, kubeconfig, checkout import, Rust build or network
dependency. `package-manifest.json` covers all archive files except itself;
`programs/manifest.json` covers every approved program/source report except itself.
Only the latter canonical manifest digest enters the authority generation.

Transfer the reviewed archive and its independently recorded checksum to the
**fresh isolated guest**. Verify the checksum before extracting as administrator
under a root-owned, nonwritable tree, such as `/root/node-authority-inputs/`.
Do not extract over an existing installation. The installer refuses imports from
a user-writable tree, including a developer's home directory or `/tmp`.

The existing Linux lab disk, metadata, history and controller files must remain
preserved. A new worker name or an empty Pod list does not establish a new domain.
The later live campaign must hold the shared lab VM lock and retain the outer
four-hour cap. These commands are for the enrolled guest, not the physical host.

## Prerequisites and configuration

Prepare the pinned Linux x86_64/K3s/SmolVM runtime and empty runtime database
through its separate administrator setup. Keep the qualified two-CPU/1-GiB
guest, 20/10-GiB runtime templates, single slot, enclosing resource limits and
offline bridge guard. Its database must have `vms` and
`vm_create_reservations`, no enrolled audit schema and no rows/reservations.
Unknown VMs, KVM processes, scoped directories, API/CRI sandboxes or controller
metadata reject setup. The installer does not initialize or repair runtime state.

Create a **canonical** configuration matching `configuration.schema.json` and
the normative contract. Use the actual prepared binding/object identities,
approved paths and hashes. The checked-in protocol vector is synthetic; never
use its identities or approvals on a node. Every configured path and its
ancestors must remain root-controlled. The authority state directory is 0700;
configuration and kubeconfig are 0600. Use the source-report hashes from the
reviewed archive. The runtime archive and K3s binary must match the existing pins.
Installation paths for the program bundle, protocol configuration and entrypoints
are fixed by the installer; requests cannot supply alternative paths.

Provision `/etc/smolbox-node-authority/observer.kubeconfig` separately with a
distinct observation credential. Review [observer-rbac.yaml](observer-rbac.yaml)
for the default names and adapt it to the approved binding. It needs read/list of namespace Pods and read
of the enrolled namespace, kube-system cluster anchor, Node and RuntimeClass;
keep observation of the enrolled offline policy and version available. It must
have no Pod create/delete/exec, runtime mutation, Secrets or general namespace
enumeration permissions. Use resource-name restrictions where applicable.
Verify these permissions, including explicit mutation denials, before enablement.
The installer validates credential custody, actual reads and 15 explicit
SelfSubjectAccessReview allow/deny controls. Those checks never attempt a workload
mutation. Review the complete effective role bindings as administrator as well;
file permissions and a finite permission probe do not establish every possible
authorization outside the enrolled scope.

An administrator-controlled empty inputs subtree under the state directory is
permitted for the configured runtime archive. Other preexisting state files are
refused. Missing VM/share/netns inventory roots can represent an empty baseline
only when their existing ancestors retain root custody. During cleanup, missing
optional runtime/guard health assets do not bypass the original history/lifecycle
proof obligations.

## Install or verify

Use an absolute root-owned mode-0600 input configuration outside the installed
configuration path. Run the extracted installer using an isolated interpreter:

```sh
/usr/bin/python3 -I -S -B /root/node-authority-inputs/smolbox-node-authority-v1/install.py \
  --configuration /root/node-authority-inputs/configuration.json
```

The installer validates source custody and manifests, fixed paths, qualified
runtime assets/versions, actual object identities, effective empty guard and a
positive empty baseline. It checks the baseline again under the audit-schema
transaction and requires unchanged node/daemon/cgroup custody. A single bounded
installation lock serializes setup. It publishes the private ledger and redacted
approval descriptor before active enrollment, and removes its installation
marker only after those files and directories are durably committed.

The output descriptor contains only the binding generation, authority generation,
verifier/configuration digests, internal history UUID and initial journal anchor.
It contains no endpoint, private key, credential, token or request-selected path.
Keep the descriptor with the administrator's independent approvals. SDK transport
configuration must use its exact expected authority and manifest digests.

An identical repeated install validates the existing installation and authority;
it does not replace files, regenerate an epoch or require the current domain to
be empty. Explicit read-only verification is also available:

```sh
/usr/bin/python3 -I -S -B /root/node-authority-inputs/smolbox-node-authority-v1/install.py \
  --configuration /root/node-authority-inputs/configuration.json --verify
```

Verification requires existing lock/enrollment/ledger/approval state and cannot
create it. It does not advance the observation ledger or repair a discrepancy.

## Restricted access and failure handling

Review [access-policy.txt](access-policy.txt) and install its principal, key policy,
effective SSH restrictions and exact no-argument sudo rule separately on the
guest. The installer creates fixed root-owned entrypoint links only. It never
edits users, authorized_keys, sudoers or sshd configuration, or restarts services.
The SSH wrapper accepts exactly `smolbox-node-authority-v1`; the root entrypoint
accepts no arguments and launches Python with `-I -S -B` and a fixed configuration.
The protocol exposes only check, capture and cleanup observation.

Real shell/subsystem/PTY/forwarding/environment/sudo negative tests remain a live
qualification gate. A socket fixture and policy example do not prove SSH policy.

Any partial installation, changed configuration/program, existing different
authority, missing/corrupt ledger, audit conflict or failed baseline stops setup.
Partial files, the installation marker and any committed audit history are left
in place. The endpoint refuses incomplete installation. Inspect the redacted
diagnostic, approved files and unresolved authority as administrator. Preserve
the original disk, receipts, history, ledgers and reservations. There is no
automatic cleanup, reset, resume, migration, rollback or active-domain upgrade.
Use a separate fresh domain for another development installation; recovery or
replacement of a charged authority requires a separately reviewed procedure.

All Python checks and this installer remain manual; no CI workflow provisions or
qualifies the node. Run the fixture campaign explicitly:

```sh
python3 -B -m unittest discover -s scripts/kubernetes -p 'test_node_authority_*.py'
```
