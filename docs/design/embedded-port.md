# Embedded Port backend design

Status: proposed, October 10, 2026. This document describes future work; it does
not claim that an embedded backend is available or qualified. The accompanying
[implementation plan](embedded-port-implementation-plan.md) defines the delivery
sequence and acceptance checks.

## Decision and scope

Add an embedded backend controlled through an Erlang Port, alongside the existing
HTTP backend. Keep Port as the default embedded bridge when Rustler is introduced;
applications may choose either bridge. Both bridges use the same Rust engine,
native machine identity, capabilities, and recovery semantics. A future native
Kubernetes backend implements the same managed backend contract independently.

The first usable Port release supports approved local image `.smolmachine`
artifacts, offline profiles, disposable executions, and retained managed machines.
It includes creation, bounded inspection, start/stop/delete, foreground execution
with streaming output, bounded guest file staging/collection, cancellation, and
durable recovery. It preserves SmolBox's explicit startup, reservations, approval
catalog, ownership checks, and refusal to replay uncertain mutations.

This release is deliberately narrower than HTTP. Unsupported features are
rejected before reservation and native dispatch; they are never silently dropped
or rerouted to HTTP. Existing HTTP functionality remains available.

| Feature | First Port release | Later work |
| --- | --- | --- |
| Approved local image `.smolmachine` artifacts | Required, including manifest/digest and topology checks | More artifact kinds |
| Neutral startup and retained stop/start | Required; preserve the current `/bin/true` default | Explicit startup workloads |
| Foreground argv, environment, workdir | Required | — |
| Guest user | Required for qualified image paths; reject elsewhere | Broader native support |
| Streaming stdout/stderr and observed exit | Required, with byte and time budgets | — |
| Finite stdin, background commands, terminals | Explicitly unsupported initially | Separate capability qualification |
| Bounded file write/read for managed execution | Required | Larger/interactive transfer APIs |
| Offline networking | Required | Controlled egress, mapped ports |
| Host mounts and local volumes | Explicitly unsupported initially | Host policy and lifecycle qualification |
| Registry/OCI sources and shared image seeds | Explicitly unsupported initially | Preparation and credential integration |
| Checkpoints, branches, exports, disk expansion | Explicitly unsupported initially | Independent optional capabilities |
| Owner-bound VM lifetime | Required and default | Detached lifetime after a separate recovery gate |
| Rustler bridge | Contract and crate boundary reserved | Additive implementation |
| Native Kubernetes backend | Contract boundary reserved | Pod/API implementation and qualification |

## Source basis and constraints

The reference checkout is smolvm 1.22.0 at
`9f446ae00219148ca4a703914f44a8e2fab11655`. It is source evidence, not proof that
embedding has passed a live qualification. Relevant entry points are
[the embedded runtime](../../external-references/smolvm/src/embedded/runtime.rs),
[native control](../../external-references/smolvm/src/embedded/control.rs),
[handle ownership](../../external-references/smolvm/src/embedded/handle.rs),
[agent management](../../external-references/smolvm/src/agent/manager.rs), and
[the internal boot entry point](../../external-references/smolvm/src/internal_boot.rs).

The implementation must account for these observed constraints:

- `EmbeddedRuntime` exposes synchronous machine and exec operations. VMMs still
  run as separate `_boot-vm` subprocesses. Rustler would embed the control engine
  in BEAM, not move the VMM into a BEAM scheduler.
- `MachineSpec` alone does not reproduce the HTTP prepared-pack creation path.
  Pack verification/materialization, VM-mode disk preparation, and provenance
  need a shared library integration. Do not translate a pack path into an image
  field and assume equivalence.
- `persistent` controls the stored ephemeral designation. `detached` controls
  parent watching. `VmHandle`/`AgentManager` destruction has separate stop/detach
  behavior. These are three different lifetime decisions.
- Streaming cancellation can return `Ok(())` without an `Exit`. A stream can
  emit `Error` and still return `Ok(())`. The public streaming callback does not
  expose the agent's initial `Started` acknowledgment. Acceptance is not guest
  execution evidence, and a successful Rust return is not a successful command.
- Convenience state methods can collapse missing records or DB errors into
  stopped/false observations. `connect_or_start_machine` may boot a stopped VM;
  some attach helpers materialize storage. Recovery needs an explicitly
  observational path with typed absence and failures.
- Inventory includes other CLI/SDK machines. Labels and timestamps do not provide
  an immutable upstream generation or authorize adoption/deletion by themselves.
- A custom `SmolvmDb` handle does not isolate all runtime paths: lower helpers
  reopen the default DB and resolve shared host directories independently.
- Image seed preparation invokes CLI `machine` subcommands through the boot
  executable. A minimal `_boot-vm` helper cannot serve those commands. Disable
  seeds for the initial embedded integration.

SmolBox currently couples managed code to
[Client](../../lib/smolbox/client.ex),
[WorkerConfig](../../lib/smolbox/runtime/worker_config.ex), and HTTP budgets in
[Observation](../../lib/smolbox/runtime/observation.ex). Its
[persistent-machine design](managed-persistent-machines.md) remains authoritative
for reservation, uncertainty, and command-slot behavior.

## Architecture

```text
Public SmolBox execution and managed-machine APIs
                  |
Managed orchestration, store, approvals, reservations, recovery
                  |
           SmolBox.Backend contract
            /          |             \
    Backend.HTTP   Backend.Embedded   Backend.Kubernetes (later)
         |               |                    |
  existing Client   Embedded.Bridge          Kubernetes API
    + Transport       /       \              + Pod ownership
                 Port          Rustler (later)
                  |                 |
             helper process      NIF resource
                   \               /
                    shared Rust engine
                            |
                smolvm library + boot executable
                            |
                 separate VMM/guest-agent processes
```

### Backend contract

Introduce `SmolBox.Backend` for managed domain operations. Do not implement Port
as an HTTP `SmolBox.Transport`: method/path/status/body semantics belong to HTTP.
Keep public `SmolBox.Client`, `SmolBox.Worker`, and existing transport extensions
compatible. The HTTP backend delegates to them.

The contract has required lifecycle, execution, file, readiness, and observation
operations, with explicit capabilities for optional operation families. Concrete
callback names and types are established during extraction, but the semantic
contract is:

| Operation family | Required meaning |
| --- | --- |
| Describe/readiness | Report backend kind, qualified engine/protocol, limits, capabilities, and bounded health |
| Create | Use approved immutable intent; return observation plus creation/ownership evidence |
| Inspect/list | Observe without starting, reconnecting destructively, or adopting foreign machines; paginate bounded inventory |
| Start/stop/delete | Mutate only a verified assignment/incarnation; deletion remains explicit |
| Exec | Deliver ordered binary output and exactly one terminal transport outcome; command success requires observed exit |
| Cancel | Request cancellation of one operation and report its actual evidence, separately from VM disposal |
| Files | Preserve bounded staging/collection, atomic write behavior, and uncertainty after interrupted transfers |
| Optional operations | Return typed unsupported before dispatch; capability admission precedes reservation |

Backend results retain `SmolBox.Error` categories and evidence. Introduce a typed
observation envelope for backend-specific identity and states. Existing
`SmolBox.Machine` and `same_incarnation?/2` remain the HTTP compatibility model;
do not squeeze frozen, paused, or unreachable native states into `:stopped`.
Those states block operations requiring a verified stopped machine.

Requests carry approved specs, ownership evidence, operation budgets, and an
event consumer. Backend-private HTTP codes, native handles, Pod names, and Port
packet details stay below this interface. Inventory and error paths redact
credentials, commands, file contents, and incidental native paths as current
SmolBox telemetry and error contracts require.

### Configuration and stable identity

Normalize existing `WorkerConfig` inputs into an internal `SmolBox.Runtime.Target`.
Add an `SmolBox.Embedded.Config` constructor for embedded targets, with stable
`id`, `bridge: :port`, absolute verified helper/package location, approved artifact
catalog, profiles, capacity, allocation floor, platform/architecture, qualified
engine build, explicit native data domain, and operation/bridge limits.

These names are proposed APIs, not runnable configuration today. Validation is
local and side-effect free; starting a configured runtime starts its embedded
helper. Merely starting the SmolBox application launches no helper or VM.

The target ID is independent of bridge choice, process PID, and helper epoch.
It identifies one reservation/ownership domain. A native data-domain descriptor
binds that ID to an operator-owned DB/cache/VM storage generation. Changing it
with retained records must fail closed and require explicit migration. Do not
automatically create a fresh domain under an old target ID.

For the first release, allow one helper and one store authority per native data
domain. Multiple BEAM runtimes may share a target only through one supervised
owner/broker with consistent approvals; otherwise reject duplicate ownership.
Hold an OS-level domain lock for helper lifetime, beyond a BEAM process registry.
Do not run Port and Rustler simultaneously against the same domain. Switching
bridges later requires quiescence and compatible domain/engine identity; it does
not migrate machines or change their logical target ID.

Native domain isolation requires an explicit upstream path-context integration,
or a dedicated OS account with verified default paths. Do not advertise arbitrary
per-target `db_path` isolation using `EmbeddedRuntime::with_db` alone. Until the
path-context integration passes qualification, restrict the host to one embedded
domain per account. Shared CLI inventory is still treated as foreign unless
durable ownership proves otherwise.

Keep admission capacity and allocation floors as operator declarations. Neither
Port isolation nor native readiness provides hard host quotas or proves actual
resource availability. Reject requests smolvm would silently clamp, including
unqualified vCPU sizes, rather than reporting the requested resources as applied.

## Shared Rust engine and packaging

Use a native Cargo workspace with these responsibilities:

- `smolbox-engine`: typed domain operations, pack creation integration, native
  identity observations, error mapping, operation/cancel registry, bounded I/O,
  and explicit handle shutdown. Depends on an exact qualified smolvm revision.
- `smolbox-protocol`: Port message DTOs and bounded framing/validation. Engine
  semantics do not depend on JSON, Erlang terms, or Rustler.
- `smolbox-port`: executable hosting the engine and stdio protocol. It also
  handles `_boot-vm` using smolvm's public internal boot entry point.
- `smolbox-nif` later: optional Rustler crate using `smolbox-engine`. Building or
  using HTTP/Port never requires Rustler or loads a NIF.

Prefer narrow upstream public-library improvements over copied implementations
or an HTTP server hidden inside the helper. The reference directory is read-only
research input; pin the implementation dependency explicitly and record any
patches/provenance. Audit the current Cargo dependency graph rather than assuming
a slim embedding feature or the missing Node NAPI crate is available.

Before constructing the engine, configure the helper as `SMOLVM_BOOT_BINARY`,
resolve the complete qualified runtime assets, and disable `SMOLVM_IMAGE_SEEDS`.
The minimal helper's only non-protocol command is `_boot-vm`; requests never spawn
the ordinary CLI to implement domain operations. Its VMM child environment must
not inherit a debug setting that writes boot logs to protocol stdout.

Distribute a separately versioned native package containing the executable,
matching libkrun/libkrunfw, agent rootfs, required disk templates, and a manifest
of versions/digests/platform/architecture. Declare host utilities such as
`resize2fs` where required. Validate assets before admitting work. Packaging must
cover dynamic-library lookup and macOS virtualization entitlements/code signing
for the executable actually launching the VMM. Runtime dependency installation
or arbitrary binary downloads never occur as a side effect of guest admission.

Select/verify the native package explicitly. The ordinary Hex dependency remains
usable without Rust, a native package, or a hypervisor. Installed assets must stay
available while detached guests or retained storage depend on them; upgrades
require draining, version compatibility checks, and a documented asset-retention
policy.

## Port protocol

Use an Erlang Port opened with `spawn_executable`, an argument vector, and binary
stream data. No shell interpolation. Implement unsigned four-byte big-endian
length framing in both endpoints: an incremental decoder rejects excessive
declared lengths before assembling the body. Do not use the Port driver's
`{packet, 4}` buffering as a configurable maximum-frame check. Erlang exposes
stream mode for user-defined framing and packet mode for length-delimited
delivery; see the [OTP Port settings](https://www.erlang.org/docs/27/apps/erts/erlang.html#open_port/2).
Each frame holds UTF-8 JSON; byte payloads use base64. This protocol has its own
version, independent of smolvm's guest-agent protocol.

Protocol stdout contains frames only. Structured logs go to stderr or a separate
bounded sink; never merge stderr into stdout. One writer serializes all output
frames. The reader continues servicing cancellation/credit/control messages
while native worker threads execute blocking calls.

Startup requires a bounded handshake before readiness. The helper reports:

- protocol major/minor, engine/smolvm versions, source/build and asset identities;
- platform/architecture, stable domain identity, and a fresh random helper epoch;
- actual supported capabilities, effective resource ranges and protocol limits;
- whether preflight checks passed, with safe diagnostic categories.

The caller approves an exact compatible tuple. Unknown protocol major, mismatched
domain/assets, missing capability, or failed preflight keeps the target unavailable.
Process liveness alone is insufficient. A handshake confirms the locally loaded
package's declarations, not remote attestation or isolation guarantees.

Messages use a request ID unique within an epoch. Responses/events include that
epoch, request ID, and monotonically increasing per-request sequence. Define
`request`, `accepted`, `event`, `terminal`, `cancel`, and `credit` messages.
`accepted` acknowledges scheduling only. Every accepted request produces one
terminal message while the channel remains healthy; channel loss is resolved by
the BEAM bridge as uncertainty, not by inventing a native reply.

An exec terminal explicitly contains completion kind, observed exit code if any,
and dispatch/running/termination evidence. A zero exit yields success only if
the stream completed without a disqualifying error. A nonzero observed exit
remains a command result according to the existing result policy. Cancellation,
deadline, or native error without Exit yields an unknown command outcome even
when the Rust function returned `Ok(())`. Never synthesize an exit code.

Freeze protocol DTOs and fixtures in the protocol phase. Proposed conservative
defaults, to verify before release, are:

| Limit | Initial value/authority |
| --- | --- |
| Maximum encoded frame | 1 MiB, validated before allocation/JSON decoding on both sides |
| Maximum binary event chunk | 64 KiB decoded; split upstream output before encoding |
| Accepted in-flight operations | 32 per helper; reject overload before native dispatch |
| Blocking work pool | 4 workers, bounded queue within the in-flight limit |
| Reserved control pool | 2 workers; cancellation token lookup/abort does not wait on a VM lifecycle lock |
| Initial output credit | 256 KiB decoded per streaming operation |
| Aggregate helper event queue | 8 MiB decoded maximum, also accounting for encoded storage |
| Output/file/command time totals | Minimum of approved profile limits, bridge limits, and remaining operation budget |

Input collections, inventory pages, error strings, nesting, event counts, and
input/output queues are bounded too. Large files are chunked rather than placed
in a single frame. Inventory responses are paginated without exposing foreign
records beyond the inspection policy.

Replenish output credit only after the BEAM consumer processes the bytes. Bound
the BEAM mailbox/aggregation as well as the helper queue. When credit or output
budget is exhausted, stop forwarding output and initiate cancellation according
to a finite deadline; do not wait forever while holding a guest socket. Treat
overflow as a protocol/observation failure, preserving any real exit evidence.
The engine must enforce its own decoded-byte cap even if BEAM stops reading.
The existing upstream collection cap also applies until a qualified streaming
path removes it; profiles must not advertise larger supported outputs.

Use nonblocking Port writes with a bounded bridge-side queue and explicit driver
busy limits. `port_command` with `nosuspend` reports a busy-port rejection;
handle that result rather than assuming successful delivery. See the
[OTP write contract](https://www.erlang.org/docs/27/apps/erts/erlang.html#port_command/3).
Credit limits bound output from the trusted helper; they do not make a replaced
or compromised native executable a memory-isolated peer. Queue saturation
before any send can be `:not_dispatched`; after a request may have crossed the
channel, preserve uncertainty. Validate duplicate/out-of-order events, IDs,
epochs, payload types, and terminal duplication. A malformed or desynchronized
channel makes the helper unavailable and resolves pending work conservatively.

The caller measures remaining time on its monotonic clock and sends a duration;
the helper independently enforces that duration after receipt. Do not compare
absolute clocks. Cancellation and terminal processing have bounded grace periods.
A stuck native call cannot be made safe merely by terminating an Elixir Task.

## Supervision, execution, and VM lifetime

Start an embedded supervisor before the managed work subtree. It owns one broker
per target; each broker owns its Port, request table, caller monitors, budgets,
and backpressure accounting. Use registered logical target IDs for lookup, never
persisted PIDs. Keep notification dispatch independent as it is today.

A helper loss marks only its target unavailable and resolves its pending calls.
It must not restart observers on healthy HTTP/embedded targets. Restart the helper
with bounded backoff/intensity; complete handshake and observational reconciliation
before admitting new mutations. Helper restart must not replay pending requests
or automatically start stopped machines.

When an observer Task dies or a caller loses its lease, the broker initiates
operation cancellation and retires the subscription, with a finite drain window.
It does not destroy the target or another machine's command. Exec uses a dedicated
agent connection and cancel token; avoid the convenience `run` path that holds
the cached VM lock throughout a command. Health and cancellation remain serviced
while exec threads block; lifecycle calls may still wait on native per-VM locks
and must respect their own budgets.

Distinguish these lifetimes:

| Lifetime | First-release behavior |
| --- | --- |
| Machine storage/record | Durable until explicit verified deletion; retained machines survive as records/storage even if their VMM stops |
| VM process, owner-bound default | Parent-watch enabled; graceful helper shutdown stops owned VMs without deleting retained disks; abrupt parent loss is separately qualified |
| Exec process/connection | Foreground operation; caller loss requests cancellation, outcome stays unknown without sufficient evidence |
| Detached VM option, later | Explicit opt-in; survive helper/BEAM loss only after handle-detach and reconnect qualification |

Graceful shutdown stops admission, requests cancellation, records uncertainty,
and performs bounded shutdown of owned native handles. It must not sweep shared
inventory, invoke global `reconcile_runtime_machines`, or delete storage merely
because a helper exits. Disposable deletion proceeds through the usual durable
ownership/cleanup pipeline, including recovery after shutdown.

Detached lifetime requires a supported engine detach-all-owned-handles operation
before destruction, explicit parent-watch configuration on every start, and
tested crash/upgrade recovery. Avoid `mem::forget` as a lifetime policy. Ship
owner-bound first if that extension is not qualified. Parent watching does not
prove synchronous guest termination; verify PID identity and stopped state before
releasing capacity or resolving cancellation.

The engine owns/reaps only its VMM children using the upstream process registry
or equivalent scoped child handles. Do not use unrestricted `waitpid(-1)`;
future NIF integration must not steal BEAM's child statuses.

## Ownership, durable state, and recovery

Persist create/lifecycle/exec intent and uncertainty before bridge dispatch, just
as HTTP does today. Backend receipts refine evidence; they never make exec
replay-safe. A helper epoch identifies a channel instance, not a durable machine
generation or a store fencing token.

Persist target binding (`kind`, stable target ID, native domain generation), the
approved immutable creation intent, and backend-specific ownership/observation
evidence. Keep bridge selection in operational configuration: Port and Rustler
must not produce different execution fingerprints for the same native target.
Native evidence may include record identity, full material creation fields,
namespaced ownership token, and verified PID/start-time for live observations.
No claim is made that mutable labels prevent an external delete/recreate attack.

Create names and ownership labels with current SmolBox identity rules, persisting
the token before dispatch. Before destructive actions, recheck the expected
record/spec and current native incarnation evidence. A name prefix or matching
label alone is insufficient. A create whose reply was lost remains unverified;
do not adopt an inventory record automatically. Stronger automatic recovery
would need a qualified durable native creation receipt/generation, which the
current source does not provide.

Recovery is observational: distinguish DB read errors, verified absence, verified
stopped, running with matching PID identity, and unsupported/unreachable states.
Do not call connect-or-start or materializing attach helpers during inspection.
Missing retained machines are never recreated. Unknown retained commands keep
their command slot until the established explicit resolution conditions hold;
canceling one must not delete its retained VM.

Retain full reservations while machines are stopped or outcomes are unknown.
Release only with the existing verified cleanup/resolution evidence. Store leases
fence durable writes, not already-sent native actions; require quiescence when
recovering an ambiguous mutation. Stable target IDs prevent a helper restart
from creating a second capacity pool for the same storage domain.

The current store codec is v15 with strict envelopes. Add the next available
selective schema version for native target bindings and evidence; do not rewrite
historical HTTP fingerprints or envelopes unnecessarily. Legacy assignments
decode as HTTP. Audit atomic reservation and machine/command operations in the
memory adapter and PostgreSQL/Ecto example; add explicit store capability negotiation
where new bindings need it. Old readers must fail closed on native records.
All controllers sharing the store/capacity authority must upgrade before enabling
native assignments; bridge rollback is separate from codec rollback.

## Rustler and Kubernetes extension rules

Rustler adds an `Embedded.Bridge` implementation, leaving orchestration and engine
semantics unchanged. NIF resources own engine handles and cancellation; bounded
native queues deliver the same event contract through BEAM messages. Blocking
hypervisor, filesystem, DB, and agent work runs in bounded native workers with
appropriate dirty scheduling for any blocking NIF entry point. Resource drop is
not assumed to confirm guest termination. The signed external boot executable
and runtime assets remain required. A native crash can terminate BEAM, which is
why Port remains a supported default after Rustler ships.

A native Kubernetes backend is not another embedded bridge. It owns Kubernetes
API resources, records namespace and immutable Pod UID, reconciles desired and
observed state, and maps scheduling/deletion uncertainty to the common evidence
contract. Artifacts, resource accounting, file/exec semantics, host policies, and
capabilities must be qualified independently. RuntimeClass/smolvm's containerd
shim may run one VM per Pod sandbox; do not equate one container with one native
machine or assume current host artifact paths are usable in Pods.

Running the existing HTTP worker inside Kubernetes is already an HTTP deployment
choice. It does not satisfy the future native Kubernetes backend. Keep transport
connection settings separate from orchestration/lifecycle kind so both deployment
models can coexist.

## Acceptance boundary

Port is ready for an initial development release only after the required feature
matrix, HTTP compatibility extraction, store migration, bounded protocol behavior,
real Linux/macOS execution, crash recovery, package consumption, and verified
cleanup pass the [implementation plan](embedded-port-implementation-plan.md).
Detached lifetime, Rustler, Kubernetes, and optional HTTP feature parity remain
separate deliverables with their own qualification evidence.
