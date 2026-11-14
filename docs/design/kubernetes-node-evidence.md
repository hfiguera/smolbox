# Kubernetes lab node evidence

This is the capture prerequisite for the development preview, qualified with the
guarded exec adapter in Phase 4. It applies only to the enrolled single-VM K3s
lab. Version-3 managed cleanup, recovery, cancellation and reservation release
passed the Phase 6 authority gate. See [progress](kubernetes-backend-progress.md), the
[exec protocol](kubernetes-backend-exec-protocol.md) and
[delivery plan](kubernetes-backend-implementation-plan.md).

## Why a transaction journal

CRI/process polling can miss a sandbox that starts and disappears between
observations. The pinned runtime's usage journal is best-effort and cannot attest
complete history. This lab instead installs administrator-owned SQLite audit
triggers on the runtime's `vms` table. Every insert, update and delete appends its
old/new record in the same transaction as the runtime write. A failed transaction
cannot publish a phantom event or commit a VM record without its event. SQLite
failure therefore fails the runtime write; it does not silently lose history.

Enrollment holds a write transaction while checking an empty VM-record and
creation-reservation baseline, empty preview namespace, no boot/KVM processes,
and empty VM-directory/share inventories. It adds separate audit tables and
triggers without changing VM rows or upstream executable assets. Enrollment is
explicit administrator setup, outside the application API. Repeated setup cannot
reset history or replace an enrolled program.

The [source review](../../scripts/kubernetes/node-history-source-basis.json)
records exact release/reference hashes. The pinned shim creates its persistent,
runtime-managed record using the CRI sandbox ID before starting the VM. Inserts,
updates and deletes use the audited database. Linux `pid_start_time` is clock
ticks from `/proc/PID/stat`, matching the typed observation. The inspector uses
read-only SQLite, CRI, procfs and network reads; it never calls a machine CLI/SDK
observation that could create directories or otherwise mutate runtime state.

## Capture and durable continuity

Each inspection opens the runtime database read-only and validates its original
device/inode, exact audit schema, epoch, contiguous sequence and autoincrement
tail. Replaying event preimages must produce exactly the live VM rows. Before
loading blobs, SQL length/count checks bound the journal to 4,096 events, 128 KiB
per record and 64 MiB total. Exceeding a bound fails closed; there is no automatic
rotation or pruning of ownership evidence.

A separate root-owned ledger retains the last journal prefix hash and immutable
sandbox-ID → Pod-UID mappings. It is written atomically and fsynced. Rewriting or
rolling back an already observed prefix fails validation. Each CRI mapping must
belong to the enrolled namespace. Deleted attempts remain in the journal/ledger
after CRI garbage collection. An attempt that disappears before its UID can be
mapped leaves history incomplete and blocks I/O and proof; it is never assigned
to whichever Pod happens to be current.

This continuity comes from the transactional journal, not a polling daemon or
best-effort event stream. Separate inspector processes and host/controller
restarts can read the same retained history. Losing the ledger, changing its
epoch, replacing the database or rebooting the node fails closed. An active
receipt cannot adopt a new observer epoch.

The first preview dispatches only one original sandbox with one observed boot
incarnation. Reinsertion, another recorded process birth, additional sandbox
attempts for the Pod, unmapped paths/processes or a changed ownership mapping
reject capture. The verifier reads the actual boot executable, exact boot-config
path, PID birth and KVM descriptors. A persisted runtime PID alone is insufficient.

The live offline bridge guard must have matching node/namespace/boot identities,
program/template hashes, exact rules, no qualification permits and fresh state.
The inspector independently verifies the current CRI/netns/bridge mapping and
checks the process incarnation again. A final journal snapshot must match the
first. The returned observation is usable for application I/O only if its typed
binding, UID, freshness, complete-history and isolation checks all pass.

## Shipped assets and runtime readiness markers

The inspector verifies the approved shim, libkrun, kernel and rootfs manifest
against the originally qualified archive identity. The engine also pre-creates
`.smolvm-ready.<VM-directory-hash>` in the shared rootfs. On the qualified
doorbell path that file is empty. It is runtime bookkeeping, not a shipped asset.

Only an exact marker name derived from a journaled sandbox can be excluded from
the shipped-asset digest, and only if it is a zero-byte regular file with one
link. Unknown names, contents, symlinks/hard links and modifications to any
shipped file still fail. The live report records the initial rejection, manifest
comparison, source review and correction before any ready receipt or application
dispatch. The journal was preserved and the inspector epoch rotated; no Pod,
runtime machine or application command was restarted for that correction.

## Host boundary and budgets

`SmolBox.Kubernetes.LabNodeEvidence` uses verified, noninteractive SSH to the
existing lab host alias and a constant guest inspection command. It does not
accept an arbitrary command or inspector path. SSH agent forwarding, PTYs and
configured port forwarding are disabled. Explicit inspector/history source
hashes approve the installed program. Connection/credential configuration is
ephemeral and excluded from persisted binding/assignment data.

One `SBH1` request/response carries a big-endian 32-bit JSON byte length and an
exact bounded body. Request and response limits include the frame header.
Diagnostics, truncated/extra/oversized frames, unknown projections and invalid
typed evidence fail without returning raw node diagnostics. Each SSH exchange
has one deadline, capped at 30 seconds. Caller loss/deadline closes its owned
channel; the guest's observation children also share the deadline and detect
input-owner loss. These children run observation commands, not machine mutations.

For exec, the enclosing operation reserves each opaque node callback's entire
granted byte allowance before invoking it: at most 65,544 bytes and one quarter
of the remaining request/response allowances. Unused grant bytes are not
refunded. API reads, node proofs and application output therefore share bounded
accounting without changing the public Budget or callback format. Small budgets
may reject a proof; callbacks cannot enlarge them or reset the operation deadline.

## Cleanup component and remaining integration

Cleanup checks the same node/observer authority, original Pod-name absence,
unchanged sandbox/process history, termination of the captured PID births, and
scoped runtime-record/VM-directory/share absence. Installed-asset or isolation
health changes do not substitute for physical proof or prevent observing cleanup
of known authority. A leaked scoped share rejects proof and remains untouched;
the verifier never repairs it by deleting it.

The live component returned valid typed proofs after UID-bound deletion and
refused an injected share leak. Those component drivers did not persist managed
cleanup completion or release reservations. Phase 6 still must integrate complete
authenticated startup scans, worker quiescence, in-flight creation/CRI
reconciliation, preparation failure and unknown-command paths, cancellation,
proof persistence and atomic release. The node `check` result is observation
health/runtime-idle information; it is not that managed reconciliation or a
capacity-release proof. The completed runtime authority gate is described below.

## Manual setup and checks

After the normal lab install and preview guard setup, sync the scripts and run
`ssh linux '~/smolbox-kubernetes-lab/lab.sh install-node-history'` with no preview
Pods or runtime machines present. The command installs files and audit schema
only inside the disposable guest. Save the reported program hashes and epoch;
construct the host provider with those approved hashes and `ssh_host: "linux"`.
An already enrolled node refuses changed source or re-enrollment. Do not edit
audit tables, discard an epoch or reuse an old receipt to bypass a failed check.

Run `python3 -m unittest discover -s scripts/kubernetes -p 'test_*.py'` and the
focused Kubernetes node-evidence/exec tests with `mix test`. These unit fixtures
do not qualify a real node. Live qualification uses the installed program, the
restricted Kubernetes service account and the assigned Backend port. All lab
checks remain manual; no CI workflow is changed.


## Phase 6 component update — CRI-bound version 2

The current inspector additionally requires original-UID CRI sandbox absence at
two points in cleanup, reports remaining preview Pods/CRI/paths as non-idle, and
waits for its observation lock within the original deadline with owner-loss
checks. Transaction snapshots already rejected creation reservations; that check
was not newly introduced. Historical version-1 proofs still decode but cannot
release through the current Memory/reference PostgreSQL store contract.

A separately approved empty-node administrator upgrade preserved the full audit
prefix and ownership mappings while rotating the verifier epoch. See
[cleanup authority](kubernetes-cleanup-authority.md) for exact hashes, evidence,
maintenance conditions, and the remaining kubelet/controller quiescence work.
Version 2 is a component checkpoint; it is not the complete preview release gate.
Do not use manual maintenance to reset history or bypass unresolved authority.


## Version 3 and managed runtime authority

The current inspector pins `node_lifecycle.py` transitively and durably captures
the original guaranteed-QoS Pod-cgroup inode/device/mount identity. Version-3
cleanup additionally requires that witness to be absent, the same cgroup2 mount,
node boot and K3s/containerd process births, plus all original API/CRI/VM/SDK/path
evidence. Missing witnesses or daemon restarts fail closed. Source review covers
all non-test kubelet Go files in the pinned K3s Kubernetes fork; exact URLs,
hashes, callers and assumptions are in the
[lifecycle source basis](../../scripts/kubernetes/kubelet-lifecycle-source-basis.json).
This witnesses kubelet progress only; it adds no VMM cgroup confinement claim.

The current observer epoch and approved program hashes, verified history-preserving
maintenance, and real version-3 release cases are recorded in
[cleanup authority](kubernetes-cleanup-authority.md). Historical v1/v2 proofs decode
but cannot release through Memory or reference PostgreSQL. No silent upgrade or
node-history reset is available to the application.

The managed runtime also requires a persistent same-host controller guard and
complete authenticated startup scans before work can execute. A different owner
cannot rely on lease expiry or helper exit. The public durable restart test
refused a paused controller, then recovered only after positive original-process
death. Unsupported production/multi-node fencing remains outside this preview.
