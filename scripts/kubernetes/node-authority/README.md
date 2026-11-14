# Standalone node authority administrator tooling

The offline builder and installer are manual. They do not provision a node, install an SSH key, change
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

## SDK construction and transport

`SmolBox.Kubernetes.NodeAuthority.new/1` constructs a redacted callback context
without opening a connection, reading a credential or installing anything:

```elixir
{:ok, node} = SmolBox.Kubernetes.NodeAuthority.new(
  ssh_host: "127.0.0.1",
  ssh_port: 22471,
  ssh_user: "smolbox-evidence",
  identity_file: "/private/approved/node-key",
  known_hosts_file: "/private/approved/node-known-hosts",
  authority_generation: approvals["authority_generation"],
  verifier_manifest_sha256: approvals["verifier_manifest_sha256"]
)
```

These example paths and connection fields must be replaced with administrator
approvals. The provider is live-qualified only for the exact fork-shim candidate
setup recorded in the versioned evidence. The example/default selection remains
`LabNodeEvidence`; standalone use requires explicit candidate and installation
approvals. The original official archive does not inherit that qualification.

Host accepts an ASCII DNS name or IP literal (IPv6 without brackets); port and
user are separate required fields. Paths are absolute ASCII paths using letters,
digits, dot, underscore, hyphen and slash. Whitespace, shell syntax, percent/tilde
expansion, traversal and inherited-home interpretation are rejected. An optional
absolute `ssh_executable` is a trusted host choice; the default is `/usr/bin/ssh`.

The transport disables inherited SSH configuration with `-F /dev/null`, agent and
default-key fallback, alternate authentication, host-key discovery/update,
proxy/local commands, forwarding and multiplexed session reuse. Only the fixed
literal token is sent. An external administrator-operated tunnel is acceptable;
pin the node key for the exact forwarded host/port in the supplied known-hosts
file. `IdentityFile=none` remains alongside the explicit key so a missing `-i`
file cannot activate default identities. See the
[OpenSSH identity-file contract](https://man.openbsd.org/ssh_config#IdentityFile).

One operation deadline includes validation, serialization, transport and typed
projection. Both frame headers count against the granted byte allowances.
Canonical receipt JSON matches the node's v1 encoding; every request gets a fresh
nonce. Responses must match that request's identity/action/nonce, exact schemas
and current typed evidence. Capture keeps the five-second/future-clock checks;
cleanup attaches only the original saved receipt and requires version 3. A
complete rejection can report its bounded error despite a nonzero helper exit;
positive evidence requires normal helper completion. No helper exit is exposed
as an application exit. There is no lab/API-only fallback.

The production source package carries the full verifier, schemas and offline
builder/installer. Building an authority archive does not require test fixtures,
a checkout or Rust. This does not constitute node/runtime qualification.

## Manual access-policy campaign

`lab.py`, `access.py` and `access-client.exs` are repository-only qualification
tools. They are not called by the SDK, shipped as node observation actions or
run by CI. The access fixture intentionally has **no node enrollment or K3s**:
only the fixed root reader's redacted unavailable response may succeed. Keep its
disk as access evidence; use another fresh guest/domain for the real runtime.

Stage `lab.py` under `~/smolbox-node-authority-lab/` on `ssh linux`, with an
`inputs/` directory containing its exact `FILES` inventory from the reviewed
existing lab scripts. Its prepare action verifies the cached cloud/K3s/SmolVM
pins and refuses an existing domain or unit. It creates a new 40-GiB disk with
4 CPUs/8 GiB and the original 4-CPU/12-GiB/no-swap/256-task/42-GiB-file/four-hour
outer limits. A QEMU-inherited descriptor retains the shared `vm.lock`.

```sh
python3 -I -S -B ~/smolbox-node-authority-lab/lab.py --domain node-authority-access-v1 prepare
python3 -I -S -B ~/smolbox-node-authority-lab/lab.py --domain node-authority-access-v1 start
python3 -I -S -B ~/smolbox-node-authority-lab/lab.py --domain node-authority-access-v1 bootstrap
```

The administrator bootstrap pins the new operator-controlled loopback endpoint;
subsequent administrative connections use strict checking. SDK evidence always
uses a separately provisioned explicit pin. Never reuse the legacy disk, keys,
controller metadata or history, or restart a stopped enrolled domain to renew
its lifetime/authority.

Copy a reviewed offline bundle, its independent archive checksum, the controller's
**public** access-test key and `access.py` into this fresh guest. Run as its
administrator with the isolated interpreter:

```sh
sudo /usr/bin/python3 -I -S -B /home/lab/access.py prepare \
  --bundle /home/lab/access-v1.tar.gz --archive-sha256 <APPROVED_ARCHIVE_SHA256> \
  --public-key /home/lab/evidence-key.pub
sudo /usr/bin/python3 -I -S -B /home/lab/access.py check \
  --report /home/lab/access-report.json
```

Preparation is exclusive and refuses any existing authority/principal/fixture.
The checks cover effective sshd policy, file custody, exact sudo, shell/subsystem/
PTY/environment rejection, all forwarding families, wrong host/key, missing-key
fallback controls, original endpoint death on disconnect and the real 30-second
partial-header deadline. A temporary root-local client key/agent exists only in
this disposable guest to test actual forbidden forwarding requests and the
default-key counterfactual. The SDK never creates or loads that test key.

`access-client.exs` consumes an administrator JSON file named by
`SMOLBOX_NODE_AUTHORITY_ACCESS` and performs the four redacted client-side controls
against that fixture, including an authenticated rejection. Its binding is a
clearly synthetic contract vector, not a node approval. Collect its report and
the server report before syncing and stopping this guest; verify the shared lock
is released. No valid execution/capture/cleanup proof can be claimed from this
campaign. Repeat effective access checks on the final enrolled installation in
Phase 5.

## Manual enrolled-node campaign preparation

`qualification.py` and `enrollment.exs` are repository-only administrator tools
for the separate fresh `node-authority-qualification-v1` guest. They do not
qualify or enable the provider. Prepare all tools and inputs before starting the
guest's four-hour lifetime. Preserve old disks and record their checksums; never
restart an enrolled domain to renew that lifetime.

Install the reviewed pinned K3s/SmolVM and preview guard inside the fresh guest
using the existing administrator scripts. Do **not** run
`install-node-history.sh`: that would enroll the separate legacy authority.
Copy the reviewed `access.py` and `qualification.py` into a root-controlled tools
directory. `qualification.py stage` requires no existing runtime database,
standalone authority or legacy enrollment. With an explicitly approved bundle it
initializes the runtime's empty base schema, provisions separate observation and
controller credentials, and writes redacted object/asset metadata under
`/root/node-authority-qualification`. It installs no evidence history.

Transfer only that metadata to the private Mac campaign directory. Run
`enrollment.exs` with `SMOLBOX_NODE_AUTHORITY_QUALIFICATION` naming that directory
to construct `binding.json` through the SDK's canonical binding and policy code.
Transfer the binding back to the fixed guest inputs directory and run
`qualification.py configuration`. Review the resulting immutable configuration
and exact hashes before invoking the offline installer separately. Positive
empty enrollment checks remain mandatory; preparation is not their substitute.

On the controller host, create its new private controller directory with mode
0700 before starting a runtime. The controller guard never creates or resets
that directory. Preserve it, all store records, and the encryption/fingerprint
keys throughout the campaign. For a distinct fresh domain, explicitly choose
new target/cluster IDs and a new PostgreSQL partition with the campaign's trusted
`SMOLBOX_AUTHORITY_TARGET_ID`, `SMOLBOX_AUTHORITY_CLUSTER_ID` and
`SMOLBOX_AUTHORITY_PARTITION` inputs. This never migrates or releases records from
another domain. Keep every unresolved original domain and its charges preserved.

After actual installation, `access.py policy --public-key <approved-public-key>`
creates the restricted principal and policy without changing the installed
authority. `access.py check-enrolled --report <new-private-report>` repeats the
real SSH controls, now requiring authenticated positive idle evidence from the
installed authority. The root-local counterfactual key is an access-test asset,
never an SDK credential. The original pre-enrollment fixture actions remain
separate and cannot be used to install over this domain.

The manual TLS fault proxy supports `--mode observe` and an explicit reviewed
`--helper-sha256`. Its bounded passive parser records only `exec`, `upload` or
`download`, discards command/environment/file bytes, and reports unclassifiable
requests rather than inventing a count. Fault modes retain their explicit lost
response/replacement controls. They simulate transport/API observations and
must be labeled separately from real node events.

Following the complete public Memory/PostgreSQL campaign, run
`qualification.py custody --report <new-private-report>` for an original-authority
positive empty/history check. It advances only the verifier's evidence ledger
and emits hashes/counts rather than raw runtime records. Preserve installation,
access, workload, failure and final custody reports before syncing/stopping the
guest. Every live gate in the implementation plan is still required.

## Public execution and recovery controls

`campaign.py` runs serial binary, silent-output, cancellation, overflow and lost
create/status cases through the public runtime. It uses `campaign_settings.exs`
and the actual Memory or reference PostgreSQL adapter, wrapped by
`campaign_store.exs` for observation. The wrapper delegates all operations and
asserts that the matching version-3 proof is already persisted while the original
reservation is held before calling the adapter's guarded release. Reports and
traces refuse replacement; a failed case stops the campaign without retrying its
application or preparing another domain.

```sh
SMOLBOX_AUTHORITY_PARTITION=<NEW_APPROVED_PARTITION> \
  python3 -B scripts/kubernetes/node-authority/campaign.py \
  --directory <PRIVATE_ENROLLED_CONTROLLER_DIRECTORY>
```

The private directory contains the reviewed settings, approvals, explicit node
key/pin, separate controller and artifact directories, and proxy TLS assets. Use
a distinct CA subject and a signed localhost server leaf with serverAuth and
localhost/loopback subject alternatives. The API proxy verifies the node CA;
the SDK verifies the proxy CA. Verify TLS and a read-only API request before
accepting any execution. A CA certificate used as its own server leaf is not a
portable replacement for that chain.

`recovery-campaign.exs` supplies manual `hold`, `resume`, `resume-held`, `standby`,
`inspect` and `probe` actions, each followed by an execution ID. Run it from the reference
durable host with the same approved partition, keys, controller directory and
settings used by the original controller. Set `SMOLBOX_AUTHORITY_STORE=postgresql`
and `SMOLBOX_AUTHORITY_PROFILE=kubernetes-preview-collection`; the latter selects
an explicit 120-second collection budget while retaining the fixed preview
resources. Keep the verified trace proxy alive throughout the case.

The `hold` action submits one binary execution with real exit 7 and parks artifact
publication for at most 90 seconds. Its private `publisher.json` and
`boundary.json` identify the actual owner PID, original Pod/process births,
deadlines, retained reservation and a second execution cancelled while queued.
Observe lease renewals beyond the five-second worker lease before advancing.
Never infer renewal from a healthy process alone.

For the collection-restart control, pause that original PID beyond its lease,
then run `standby` and require refusal with the original charge retained. Kill
only the identified original controller, wait for its exit, and run `resume` with
the same execution ID. Resume performs no submit. Require the original exit,
deadlines and output hash, one traced application request, original-UID deletion,
persisted v3 proof and zero final usage. Download retries may occur; application
replay may not. Cleanup may repeat a DELETE guarded by the same original UID
within its persisted mutation deadline. Count creates and application requests
separately from these safe disposal retries; require every DELETE to name the
original UID and preserve the original cleanup deadline.

Use `resume-held` for the collection-restart check. It submits no work and parks
the recovered publication in a new `recovery-publication` gate under the original
execution's directory. Observe renewed worker leases after that publication has
exceeded the five-second lease, then create its `publish.allow`. Require the
original collection deadline, exit and VM/Pod identity to survive this interval.
This distinguishes recovery publication from the first controller's collection.

`observation_lock.py` is a separate root administrator tool for the dedicated
guest. It holds only the **existing** authority lock until stdin EOF, with a
30-second hard cap. It never creates, removes or repairs authority files. While
it holds that lock, start `probe`, observe the original endpoint birth with
`--inspect`, and kill the probe's identified controller PID. Require bounded
original endpoint exit and unchanged original VMM births/KVM descriptors, then
close the operator's lock channel. The inspection output excludes command and
file payloads. This control interrupts a real read-only observation without
killing a workload or changing its deadline.

For the authority-retention control, the optional trusted `ssh_executable` can
point to a private copy of `negative_ssh.py` with sibling `evidence-fault.json`.
Mode `real` execs the normal SSH binary unchanged; mode `unavailable` produces
only a matched synthetic rejection. Select it with
`SMOLBOX_AUTHORITY_FAULT_SSH`. After publication is parked, switch to unavailable
and create `publish.allow` in that execution's gate directory. Require the real
exit and published artifact to survive while cleanup remains unproven and
capacity held. After positive original-owner death, return to real SSH and test
separate controllers with `SMOLBOX_AUTHORITY_BAD_APPROVAL=manifest` and
`generation`; each must retain the charge. Stop each identified controller before
the next. Finally restore the original approvals and resume the original record.
These are explicitly synthetic availability/approval controls, not evidence of a
real node failure, and cannot produce positive physical proof.

Preserve every failed observation, original record and active process identity
before deciding the next action. Never change an enrolled verifier, substitute a
global idle check for an original receipt, or force release to finish a campaign.

## Explicit fork-runtime candidate validation

The user-authorized shim fix is developed separately in `hfiguera/smolvm` on
`feature/smolvm-shim-child-waits`. Its Linux regression boots the real
containerd-shim framework and deterministically reproduces an exit stolen from
a successful `cp`. The selected integration uses the engine's existing per-PID
VM reaper, keeps ordinary helpers owned by their `Child` handles and leaves
unregistered orphan adoption to the supervising ancestor. The real framework
checks cover helper exits/signals/concurrency/cancellation, registered VM exits
without a liveness query and orphan cleanup. Their task-service stub supplies
no KVM or public-execution qualification evidence.

For the SmolBox candidate, backport the same change to the exact v1.34.0 source.
`candidate_runtime.py` accepts the checksum-pinned original archive, the reviewed
Linux x86_64 shim digest and exact backport/upstream-fix revisions. It produces a
new deterministic archive replacing only `containerd-shim-smolvm-v2`; all other
original member content and metadata remain preserved. It refuses unapproved
inputs, another architecture and existing output. The archive is labeled
**candidate only**, with a new approved archive and shim identity. It is not the
official v1.34.0 artifact and does not inherit its qualification.

Run `qualification.py stage` on a **fresh guest only**, passing the explicit
`--runtime-archive-sha256` from that candidate's reviewed report. Without this
option the original runtime pin remains the default. Pass that same approval to
the separately reviewed offline `install.py` invocation, including `--verify`.
An override cannot change the archive recorded in the immutable binding; a
mismatch refuses installation or verification. It does not qualify the candidate.
The positive-empty checks,
restricted access, exact installed asset verification and immutable enrollment
are unchanged. Never replace an enrolled verifier/runtime, migrate an old receipt
or release an old charge using the candidate. Repeat the complete public
Memory/PostgreSQL and recovery/access/transport/authority campaign under the
shared lock and four-hour cap before claiming the candidate setup is qualified.

## Unresolved authority and escalation

Cleanup can remain charged after the mutation deadline and later complete from
a fresh bounded read-only proof. Preserve that distinction in reports: a delayed
positive proof is not immediate cleanup, and increasing an observation grant
outside the runtime does not change the runtime's original budgets or deadlines.

A preparation failure may leave only a created receipt, without the original
ready VM/KVM/cgroup witness. Deleting its original Pod or obtaining a complete
node-wide idle/history check cannot replace that missing witness. Both fresh live
campaigns observed this after the pinned SmolVM runtime reported `No child
processes` while copying an etc-hosts mount. Their unresolved PostgreSQL charges
and stopped guests are preserved in the versioned Phase 5 evidence. No runtime fix or
new release authority is inferred from successful work on another fresh domain.

Escalation preserves original store records and encryption/fingerprint keys,
controller metadata, Pod UID/receipt, installed programs/configuration,
history/ledger, node events and guest disk. Stop admission and investigate the
recorded runtime failure or missing witness. Any repair requiring different
physical proof, durable fields or ownership semantics needs its own reviewed
versioned design. Do not delete evidence, reconstruct a ready receipt from a
global inventory or force release. A separate new installation needs a fresh
guest/domain, positive-empty baseline, binding, controller directory, keys and
store partition; it cannot adopt or clear the old domain.

History is bounded and cannot be compacted or rotated in this release. Node
reboot, daemon restart, lost continuity or ambiguous interrupted publication
stops authority. There is no supported active-domain verifier upgrade or storage
rollback. Keep the exact enrolled bundle and approval descriptor available for
inspection; replacing them with older or newer files cannot restore an old
epoch. Archive the unresolved domain and design recovery separately rather than
reinstalling over it.
