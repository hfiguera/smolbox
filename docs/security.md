# Deployment and trust boundaries

SmolBox relies on
[SmolVM's isolation model](https://github.com/smol-machines/smolvm/blob/e8d09ef616d363004d55b80a6cdb31a4e7e1842d/SECURITY.md)
for running untrusted code. Each part of a deployment has a separate responsibility:

| Component | Responsibility |
|---|---|
| SmolVM and its virtualization stack | Run each workload in its own VM and defend the guest-to-host boundary under the upstream security model |
| SmolBox | Manage execution identity, admission, observation, bounded collection, uncertain outcomes and cleanup |
| Application and deployment | Authorize access, approve images, protect worker interfaces, enforce host resource limits, configure networking and credentials, and operate durable storage and recovery |

SmolBox does not provision a worker, proxy, database, image registry or hypervisor.
The library's supported qualification remains `:development`; it does not install
or attest host resource controls. Requested unsupported hard-control options
remain rejected.

After the 0.1.0 release, a Linux campaign verified external resource enforcement
and failure recovery on one pinned nested deployment. See the
[validation summary](resource-qualification.md#subsequent-linux-deployment-validation)
and the full
[Linux qualification guide](https://github.com/hfiguera/smolbox/blob/main/docs/linux-production-qualification.md).
Those results apply to that configuration: one execution at a time, approved
images, no guest networking, host mounts or production secrets. They do not
extend to arbitrary images, concurrent tenants or macOS host limits.

## What must be trusted

The Elixir application authorizes users, assigns scopes and selects approved
profiles and artifact revisions. A `{scope, execution_id}` handle is an identity,
not a bearer authorization token. Keep the low-level client, worker configuration,
orphan inspection and full stored execution records behind host authorization.
Never expose arbitrary worker endpoints, artifact host paths or profile controls
as user-editable request parameters.

Guest commands, their dependencies, output and files may be hostile. The host OS,
hypervisor, VMM, SmolVM server account, worker proxy, Elixir VM and configured store
adapters are trusted infrastructure. Guest root cannot attest exactly-once
execution or enforce a host safety boundary. Telemetry handlers and artifact-store
adapters are trusted host code; they do not execute inside a microVM.

An approved prepared `.smolmachine` is also a trusted deployment input. Its guest
code can be untrusted, but the host must verify its architecture, immutable bytes,
neutral entrypoint, disabled restart policy and absence of embedded credentials or
unexpected runtime configuration. A SHA-256 identifies bytes; it is not a security
review. Store approved runtime artifacts in an operator-owned, non-writable catalog.
Do not accept a guest-uploaded archive as a worker artifact or unpack it on the host.

## Worker account and control interface

Use a dedicated worker account and private state/storage locations. Keep it away
from application credentials, source checkouts, SSH agents, cloud metadata
credentials and unrelated workloads. Separate tenant pools when their trust or
retention policies differ. One physical worker must have one authoritative store
and an exclusive namespace owner. Endpoint aliases and separate stores do not
create worker-side coordination or command fencing.

Bind `smolvm serve` to a private loopback or verified local Unix interface.
Remote access goes through an operator-supplied authenticated TLS proxy. SmolBox
requires a bearer token and certificate verification for remote HTTPS endpoints;
HTTP is restricted to an explicitly permitted loopback development endpoint.
The API is powerful control-plane access, not a public guest service. Restrict
host firewall/routing and proxy authorization to authorized controllers. Tokens
remain in the controller/proxy configuration, never guest command environment.

The proxy must reject unauthorized requests before forwarding, validate backend
routing, avoid following redirects, impose finite request/body/concurrency limits,
and support the needed SSE response behavior. Disable automatic upstream retries
and failover for mutations, especially exec. Bound queue time, connection lifetime
and idle time; record their interaction with the controller's budgets. Proxy logs
must exclude authorization headers, command/file bodies and returned output.
The disposable TLS test proxy is a qualification fixture, not deployment software.

Authenticated transport does not provide execution receipts, durable deduplication
or request fencing. A request already accepted by a proxy can outlive its original
controller. Stop/delete observations cannot prove that a delayed exec will never
start a VM. Preserve unknown outcomes and reservations under the documented
[recovery rules](recovery.md); do not automatically fail over an uncertain command
to another worker.

## Minimal configuration and current enforcement limits

Managed execution rejects unsupported profiles and always requests no guest
network, host mounts, forwarded ports, host sockets, GPU/CUDA or nested Docker.
It uses approved prepared artifacts with `/bin/true` and restart policy `never`.
Image preparation happens separately under host policy; a failed offline execution
never authorizes networking or an arbitrary image pull.

Linux deployment results below refer to that specific externally constrained
configuration. The library's profile options do not configure its host controls.

| Control | Observed behavior | Scope and limitations |
| --- | --- | --- |
| Concurrency and reservations | Atomic store admission for the documented ownership topology | Does not coordinate an unrelated store or external worker users |
| vCPU allocation | Requested, decoded and matched; real guests on both platforms report one CPU | Allocation is not a CPU-time quota; host contention remains external |
| Guest memory | Finite overload experiments on both platforms record guest OOM evidence while the command parent and VM survive | No universal host-RSS bound or complete hostile-memory certification |
| Host CPU/memory/tasks | The Linux deployment recorded CPU throttling, an OOM kill at 1.5 GiB charged memory, and task denial under a 96-task cap | External worker controls; CPU bandwidth is not CPU time, charged memory is not process RSS, and host tasks are not guest PIDs; macOS enforcement was not tested in this campaign |
| Disk | Verified template allocation floors and reservations; the later Linux deployment filled its 768 MiB VM/cache mount while separate 64 MiB control storage retained space, and API deletion succeeded | The earlier shared-storage cleanup failure remains relevant to that layout; these external worker quotas are not per-execution library options or evidence for macOS host limits |
| Guest process count | No certified hostile-guest process limit | Guest root cooperation or a Python/JS wrapper cannot supply it |
| Deadlines/cancellation | Persisted budgets and observed owned-VM stop; the Linux deployment also passed an independent 300-second worker deadline and frozen outer-VM recovery | The worker unit has a five-second stop grace; outer-kernel failure falls back to the physical host's 45-minute QEMU deadline plus stop grace; delayed requests remain unfenced |
| Output | Bounded BEAM capture and transport; finite overflow and blocked-observer tests, including a contained Linux producer, preserve the available evidence | Arbitrary hostile-protocol behavior and total server/channel/frame memory remain unqualified |
| Egress and credentials | Offline configuration; tested public TCP and selected guest-to-host routes fail; initial credential-sentinel checks | These probes do not certify every host route, credential source or protocol |

Run resource-abuse tests only inside independently verified host limits. A profile
field, health response, API allocation echo or successful ordinary command does
not verify the kernel enforcement boundary. Keep sparse disks, shared layers,
runtime caches, VM logs and failed-cleanup retention within separate host budgets.
Guest processes and host VMM threads are different quantities. No user-supplied
hard CPU-time, host-RSS, process-count or host-disk-byte setting is accepted by the
current library.

Configure `SMOLVM_FILE_TRANSFER_MAX_BYTES` on the worker before starting the
server. The tested installation uses 1 MiB; the pinned release's default 4 GiB
is inappropriate for this small-file contract. Client download limits protect
the controller after the server has performed its own work; they cannot replace
server-side limits. The pinned SSE bridge uses an unbounded channel by message
count and an 11 MiB aggregate relay cap plus a frame. This is not a proven total
worker memory limit. Networkless guest configuration also does not prove that
all host-agent control paths are inaccessible to hostile guest code.

## Files and persistence

Use exact validated `/workspace` paths and bounded manifests. SmolBox does not
recursively unpack guest archives or select outputs with wildcards. Lexical path
validation cannot establish race-free symlink containment inside an actively
changing guest. Collected files are bounded individual snapshots, not an atomic
filesystem snapshot. Keep guest-derived names and bytes out of host path-building
logic except through a conforming artifact adapter.

The pinned prepared Python artifact follows a `/workspace` symlink on download
even when its target is elsewhere inside the guest. Both Linux and macOS tests
read a guest-only `/tmp` sentinel through such a link. Upload replaces that link
with a regular file and leaves its former target unchanged. This is not a host
filesystem escape, but it means workspace-only canonical containment is absent
for this artifact path. An extra guest `stat` before download cannot close a
hostile symlink race. Keep secrets out of the entire guest image and do not claim
workspace containment from the lexical API restriction.

A guest FIFO is another tested limitation: the agent opens the path before its
regular-file check, so a read with no writer can block. The client operation
deadline returns a transport error; stopping and inspecting the owned VM clears
the blocked guest. Neither that deadline nor a rejected oversized response is a
successful file transfer or confirmed guest termination. The worker's configured
1 MiB file cap rejects a 1 MiB-plus-one file with an HTTP error; a smaller client
cap independently rejects an oversized response.

Finite output tests also distinguish verified results from missing evidence.
An 8 KiB buffered response exceeding a 128-byte output allowance retains the
received exit code in its typed error. The equivalent interrupted SSE capture
reports uncertainty with no exit code. A blocked callback expires while a finite
512 KiB guest producer can finish and write its test marker; expiry kills the
local observer, not the VM. These measurements do not bound total worker memory.

The directory adapter requires a private root, bounds bytes and verifies immutable
publication. It is not a general multi-host object store, hostile-host filesystem
defense or persistent global disk quota. The host owns durable object retention,
encryption, backups and cleanup independent of VM retention. Artifact-store
unavailability preserves command exit evidence and reports collection failure.

Use a durable conforming store when restart recovery matters. The included
Postgres adapter is an example host project, not a library dependency. Its
fingerprint and encryption keys must survive restarts and remain private. Hosts
own migrations, backups, access control, key rotation and record retention.
Never replace an unavailable store with memory or generate a new fingerprint key
for old identities. Memory mode is explicitly ephemeral and loses authority when
its store process stops.

## Upgrades and operator recovery

1. Stop accepting new work for the target pool and persist its drain policy.
   Runtime-local drain excludes later admission-task launches; already active
   admission or execution can still finish. It is not a worker-side fence.
2. Inspect outstanding records, reservations, unknown outcomes and cleanup.
   Keep old worker routes and artifact evidence available until their ownership
   has been resolved. Do not delete resources by prefix or release a reservation
   just because an unverified create temporarily returns 404.
3. Back up durable state and required keys. Apply host-owned migrations explicitly
   and verify the store contract before starting the new controller. Follow the
   durable example's authenticated index backfill instructions for its older schema.
4. Pin and verify the new binary, schema and artifact bytes on a separate candidate
   worker. Recheck template sizes, VMM overhead, network behavior, proxy semantics,
   host quotas and all advertised platform tests. SmolBox 0.1.0 admits
   only the qualified SmolVM 1.14.1 contract; a different version is incompatible.
5. Give changed artifacts/profiles new immutable revisions. Do not rewrite saved
   execution specifications or resubmit a changed specification under an existing
   identity. Recovery rechecks current approval before a prepared command dispatches;
   revocation cannot undo a command that might already have been accepted.
6. Start one owner with the existing store and keys, inspect reconciliation, then
   reopen admission only after the host has verified compatibility and capacity.
   Rollback must also preserve original identities and avoid overlapping owners.

For exhausted cleanup, investigate stored creation evidence and current worker
state before taking an explicit operator action. `reconcile` can observe later
absence of a verified resource; it cannot authorize replay or override ownership
conflicts. Retain an audit of manual actions outside SmolBox's optional telemetry.
Never interpret a cancelled HTTP request, dead controller or expired `await` as
confirmed guest termination.

## Worker storage exhaustion

An earlier contained Linux 1.14.1 probe filled its private 512 MiB data mount. The guest
observed a write I/O error and could be stopped, but SmolVM could not commit its
VM deletion because its database shared the full mount. SmolBox correctly
reported uncertainty; an observed stop does not confirm cleanup. Retain the
execution's reservation and ownership evidence through the normal cleanup path.

Operators need verified headroom for control metadata or separately bounded
storage, and an owned-worker recovery procedure for exhausted storage. The
experiment recovered by destroying only its separately bounded, verified owned
unit and private in-memory mount. This cannot be generalized to deleting a
shared worker's data or all machines with a matching name prefix. See
[resource qualification](resource-qualification.md) for exact limits, counters
and the recorded shared-storage failure.

The subsequent nested Linux deployment separated its 768 MiB VM/cache mount
from its 64 MiB control-metadata mount. Repeating disk exhaustion filled the
VM/cache mount while metadata retained free space; owned stop, API deletion and
absence inspection all succeeded. This resolves the observed cleanup problem
for that storage layout. It does not change SmolVM's behavior when data and
metadata share an exhausted filesystem. See
[Linux deployment validation](resource-qualification.md#subsequent-linux-deployment-validation)
for the tested configuration and recovery evidence.
