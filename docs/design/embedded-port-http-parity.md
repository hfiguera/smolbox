# Embedded Port HTTP feature parity

Status: implementation in progress, October 13, 2026. Checked coverage, clean API
witnesses, shared approval/feature foundations, bounded observations and native
network/port/workload intent translation are implemented. Full parity acceptance
and ordinary qualification remain pending; this document does not qualify them.
Implement on `embedded-port-design-non-upstream-patches`.

The [unmodified-SDK migration](embedded-port-unmodified-sdk.md) and its
[completion audit](embedded-port-unmodified-sdk-completion-audit.md) remain a
completed, narrower milestone. This design expands the branch's next milestone
from offline execution to HTTP feature parity. Its companion
[implementation plan](embedded-port-http-parity-implementation-plan.md) defines
the implementation and acceptance gates. Crash validation remains deferred.

## Decision

An application should select HTTP or embedded Port according to where and how it
operates its runtime, while retaining the same supported SmolBox workload and
managed-operation semantics. Implement the features exposed by SmolBox's HTTP
backend, including their existing limitations, rather than every endpoint or
feature offered by the upstream smolvm server.

Parity covers public managed APIs and the operations in `SmolBox.Backend`.
`SmolBox.Client`, custom HTTP transports, HTTP headers, URLs, TLS and WebSocket
handshakes remain HTTP interfaces; an embedded target does not emulate a server
or accept a pretend HTTP client. Common application operations keep their existing
specifications, result types, approval rules and durable identities.

Preserve the Port process boundary and the shared Rust engine. Rustler remains a
future additional bridge to that engine; Kubernetes remains a separate future
backend. Do not introduce a Rustler dependency or implement either future backend.
Keep the unmodified SDK dependency, complete source verification and normal locked
dependency versioning. No fork, downstream patch, dependency source rewrite,
hidden CLI fallback or local HTTP server is an acceptable shortcut.

The initial source baseline remains SDK 1.22.0 revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. Public API availability is preliminary
feasibility evidence, not proof of equivalent behavior. If a required feature
cannot meet the contract on that source, record the precise blocker and evaluate
an unmodified official SDK upgrade separately. Do not silently narrow parity or
reintroduce patches.

## Parity baseline and operation matrix

The [checked coverage manifest](embedded-port-http-parity-coverage.json) tracks
operation signatures, specification features and explicit pending acceptance.
Its unit contract compares the inventory with the actual adapters. The
[native API audit](../../native/http-parity-api-boundaries.md) records clean-source
feasibility and the remaining ownership/resource gates without enabling features.

The executable baseline is `lib/smolbox/backend.ex`,
`lib/smolbox/backend/http.ex`, `lib/smolbox/client.ex`,
`lib/smolbox/branch_client.ex` and the public feature guides. HTTP advertises
operations whose eligibility still depends on runtime version, platform, approved
source/profile and store capabilities. Embedded parity must preserve those
constraints. It does not make every feature valid for every machine.

In this matrix, **existing** means the operation is present in the current
embedded adapter, not that its expanded combinations already pass. **Add** means
the adapter does not currently implement the HTTP operation. Arity overloads in
`SmolBox.Backend.operations/0` belong to the same row and require coverage.

| Backend operations | Current Port | Required behavior and restrictions | Plan |
| --- | --- | --- | --- |
| `health`, `capacity`, `metrics`, `readiness`, `observe_health` | Only `observe_health` exists | Correct version/capabilities, configured admission capacity, truthful observations and bounded readiness without mutation | P1, P2 |
| `list`, `inspect_machine`, `machine_measurements` | Only `inspect_machine` exists | Equivalent bounded observation types; distinguish measured usage from configured/reserved resources; inventory never supplies ownership | P2 |
| `create`, `create_prepared`, `prepare_artifact` | Local `create` exists | Approved local, registry, OCI and checkpoint workflows; separate preparation and creation identity/deadlines | P3, P4, P7 |
| `start`, `stop`, `delete` | Existing | Preserve ownership and ordinary behavior across workload/network/storage/source combinations | P3–P8 |
| `exec`, `exec_stream` | Foreground without stdin | Buffered UTF-8 stdin, existing foreground streaming, qualified background launch; preserve result and dispatch evidence | P5 |
| `upload`, `download` | Existing | Preserve bounded atomic writes/reads and profile path authorization across added machine kinds | P3–P8 |
| `logs` | Add | Bounded console diagnostics, tail/follow/callback options; no implicit boot or inference of application completion | P5 |
| `terminal_preflight`, `open_managed_terminal` | Add | Existing managed terminal API, single consumer, input/resize/close, bounded output and unchanged no-reconnect/no-replay semantics | P6 |
| `list_images`, `pull_image` | Listing/pull wired; activation pending | Existing-machine image inventory and approved digest-pinned pulls; managed pull is restricted to OCI-created machines | P4 |
| `provision_volume`, `delete_volume` | Add | Linux local volumes, exact approved root, exclusive attachment and independent retained disk accounting | P7 |
| `expand_disks` | Add | Idle created/stopped machines; absolute 1–64-GiB targets, growth only, no implicit stop/start, immutable creation intent | P7 |
| `start_checkpointable`, `checkpoint_preflight`, `capture_checkpoint` | Add | Approved idle offline bare guests, bounded portable capture, source resumes, no external/container/network dependencies | P8 |
| `export_machine` | Add | Stopped-machine supported disk export and approved registry destination; no implicit stop, checkpoint semantics or container workspace export | P8 |
| `branch_source`, `branch_absent`, `branch_create`, `branch_inspect_child`, `branch_release` | Source preflight wired; activation and remaining operations pending | Same-worker offline bare source, one leaf, explicit hold/release, source dependencies and extra backing reservations | P8 |
| `qualify_creation`, `inspect_creation`, `qualify_growth`, `qualify_capture`, `cleanup_capture` | Native-only implementation | Keep pre-dispatch qualification, non-mutating verified absence, explicit quiesced growth/capture proof qualification and exact capture staging release. Capture qualification/cleanup never replay capture or adopt an artifact. HTTP intentionally does not implement these operations | P1, P7, P8, P9 |

The following specification features also require coverage even though they are
not individual backend operations:

| Specification feature | Required parity boundary |
| --- | --- |
| Outbound networking | Exact `SmolBox.NetworkPolicy` host/CIDR approval, default offline and explicit network-backend observation |
| Inbound ports | Retained TCP mappings and durable port reservation; offline egress may coexist with inbound forwarding |
| Startup workload | Existing `Workload` argv/env/workdir/user semantics, `restart: :never`, image inheritance and no implicit application readiness claim |
| File access | Existing `GuestPaths` authorization and bounded file budgets; absence of an HTTP client must not remove host approval checks |
| Registry credentials | Resolve safe credential references per bounded operation; never persist, log or place tokens in argv |
| Checkpoint restore | Approved runtime/platform/architecture/CPU compatibility and fresh owned identity; normal stop/start is not another memory restore |
| Local mounts | Approved managed volume sources/targets/modes and Linux qualification; do not add arbitrary host-directory mounts absent from the public managed HTTP contract |
| Draining and replacement | Block new assignments and resource additions, continue permitted retained work/cleanup, quiesce before normal helper replacement |

Use the current HTTP feature guides as the restriction baseline:
[networking](../network-access.md), [ports](../port-mappings.md),
[images](../images-and-registry-artifacts.md), [workloads](../workloads.md),
[terminals](../interactive-terminals.md), [volumes](../local-volumes.md),
[disk growth](../disk-expansion.md), [checkpoints](../managed-checkpoints.md),
[exports](../machine-exports.md) and [branches](../managed-branches.md).

Linux x86_64 and macOS arm64 remain the ordinary native platforms. Volumes remain
Linux-only. Disk-growth qualification is currently Linux-only in the HTTP guide;
do not describe macOS growth as qualified without a separate passing campaign.
Preserve each feature's more specific platform/source restrictions. New embedded
gaps on an otherwise supported HTTP platform remain pending, not exceptions that
allow declaring parity complete.

## Shared target policy and capability negotiation

Today `Embedded.Config` accepts only local artifact catalogs and offline profiles,
and `Runtime.Target.normalize/1` fills optional catalogs with empty lists. Extend
embedded configuration with the same source/checkpoint/export/branch/volume and
credential approvals as the HTTP target. Extract shared validation where its
semantics match; retain endpoint and package/domain validation in their adapters.
Allow source-only catalogs where the HTTP contract permits them.

Separate SDK version, SmolBox engine version and bridge protocol version.
The current embedded target exposes engine `0.1.0` as `runtime_version`, while
feature coordinators check SDK values such as `1.22.0`. Simply enabling adapter
operations will still reject those workflows. Keep existing HTTP version checks,
and use explicit SDK identity and negotiated feature predicates for native
targets. Never make a helper claim an HTTP server version or treat an engine
version as a compatibility proof.

Introduce one backend-neutral feature description used by scheduling, target
approval, operation preflight and documentation. Native package policy and Hello
must agree on supported feature versions, platform/source restrictions and
finite limits. Operator approval narrows this description; it cannot enable a
feature absent from the approved helper. Admission must reject unsupported
intent before reservations and native dispatch.

Extend the wire protocol with a new major version for expanded operation shapes,
interactive control and versioned native material proofs. Preserve an explicit
legacy 1.3/1.4 path for previously approved packages; do not reinterpret their
strict capability list or receipt schema. New source/build/asset/policy bytes need
new manifest approval. Compatibility readers do not authorize changed packages,
old-domain adoption, overlapping helpers or automatic receipt conversion.

## Engine, workers and streams

The shared engine owns receipt validation, approved policy, operation identity,
machine/source gates, host children, native jobs and result evidence. The Port
adapter owns framing and translation. Neither a future NIF nor a Port adapter may
call the SDK directly or establish a second domain owner.

Keep blocking I/O away from the Elixir Port owner and from control capacity.
Generalize the existing bounded worker supervisor for operations whose clean SDK
calls cannot be interrupted safely in process: buffered stdin execution, terminal
sessions, image transfer, capture/export streaming and long preparation where
needed. A worker uses controller-authorized existing resources; it cannot create
ownership or boot an unaccounted machine. Lifecycle jobs that need SDK mutation
stay under engine authority. Do not casually construct a second `EmbeddedRuntime`
inside a subprocess.

Preserve the four work slots and two reserved control slots as the initial
defaults. Terminal sessions consume explicit work capacity; they cannot starve
cancel, drain, health or cleanup. Add finite budgets for queued bytes, terminal
input/output, artifact/capture/export staging, FDs, subprocesses and auxiliary VMs.
Any changed aggregate limit is a protocol/package-policy change with evidence.

Command/file caps do not become artifact caps. Captures and exports may exceed
the existing 16-MiB command/file limit under their explicit policy bounds. Stream
them into the controller's existing private file sink in bounded chunks, with
incremental hashes, credit and publication after complete verification. Never
assemble a multi-GiB result in a JSON frame, Elixir mailbox or native buffer.

One absolute monotonic budget covers preparation, queueing, SDK entry, transfer
and collection. Input send acknowledgment proves local submission, not guest
consumption. Process exit is not a guest acknowledgment. Cancellation closes
observation/attempts and collects owned workers; it does not prove guest command
termination, rollback or absence. Unknown outcomes retain relevant reservations,
leases and dependencies and are never automatically replayed.

## Ownership and legitimate material changes

The present receipt hashes the SDK record's material fields. Network policies,
workloads, disk sizes, checkpoint metadata and branch dependencies can change
those fields. The current assignment validator also requires all optional
histories to be empty. Removing those checks or rehashing whatever is found in
the DB would destroy ownership verification.

Introduce versioned native material proofs that separate immutable creation and
incarnation identity from specifically authorized material transitions. A
transition binds the full existing authority, operation ID, prior proof and exact
approved request. The engine verifies preconditions, records bounded local
operation evidence, calls the SDK under its gate, and returns a new proof only
after a correlated supported result and verified postcondition. Native evidence
is not a replacement for the Runtime's authoritative durable intent/history.

Keep the creation spec, fingerprint and original creation evidence immutable.
Disk growth and other legitimate evolution are represented by existing durable
operation histories plus their native transition proofs. Detect unrelated record
changes as ownership conflicts. If a result or proof is lost, observation can
reconcile already recorded authenticated operation evidence; it cannot adopt a
DB row, create a missing receipt or repeat the mutation. An incomplete transition
remains unknown. Define this recovery contract before enabling any feature that
changes material.

Use versioned persisted shapes and update Memory/PostgreSQL validators/codecs
together. Preserve v16 and all legacy HTTP readers. If the new record shapes need
a later codec, introduce an explicitly selected new version and reader-first
upgrade procedure; never persist expanded records under the old v16 semantics.

Gate all cooperating mutations and I/O activation; acquire source/child gates in
stable order. Keep existing SDK flock ordering: a lifecycle API that acquires its
own source lock must not be wrapped in a second acquisition of that lock. Receipt
checks remain immediately before SDK entry and after mutation. Independent CLI
writers and simultaneous Port/Rustler owners remain unsupported.

## Networking, ports and startup workloads

Translate the existing policy into public SDK `MachineSpec`/egress fields and
verify the resulting backend and allowlists. Enforce the same hostname/CIDR
validation and infrastructure exceptions described by the HTTP network guide.
Do not widen destinations for image downloads or readiness checks.

Port mapping does not require unrestricted egress. Offline-with-ports explicitly
requests the supported network device and empty outbound allowlists. Hold exact
`{target_id, host_port}` reservations from acceptance until verified deletion,
including stopped machines and unknown outcomes. Loopback publishing is the
default; any worker-wide bind configuration must be approved and observed during
setup. Application readiness and connection draining remain application concerns.

Workload creation uses the SDK's public workload path and the existing argv/env/
workdir/user rules. Omitted workload remains neutral startup; explicit empty argv
inherits the image defaults. No automatic restart policy is introduced. A running
VM does not attest successful application startup. Normal stop/start relaunches
the configured workload as in HTTP. Preserve qualified numeric-user restrictions
unless broader upstream behavior is separately verified.

## Images, preparation and auxiliary resources

Preserve three distinct operations: registry `.smolmachine` host preparation,
OCI creation and existing-machine image pull. Match platform manifest identity,
prepared content digest and observed image/configuration identity separately.
Listing images is not listing the host artifact cache. OCI pull on an imported
pack must not turn synthetic `packed` metadata into a successful download result.

Host registry traffic is separate from guest egress. Keep explicit TLS/trust,
redirect, destination and credential handling at the host preparation boundary;
OCI creation still requires an approved guest network policy. Resolve registry
credential references without copying tokens into durable records, public
messages, argv or inherited process environment. Pass secrets only through
bounded private IPC for the authorized operation and redact diagnostics.

Current engine startup requires `SMOLVM_IMAGE_SEEDS=0`; changing that environment
flag is not a seed design. Keep shared seeds disabled initially. Before enabling
SDK seed reuse or a temporary builder, prove enrollment in the owner epoch,
account its extra capacity/staging/cache lifetime and prevent hidden CLI boots.
Non-seeded OCI must still meet parity unless seed behavior is made an explicit
additional approved feature. If even that path launches auxiliary work, account
and guard it before admission. Reuse SDK formats/download/materialization code
through audited callable APIs, not copied HTTP handler logic.

## Commands, logs and terminals

Buffered foreground execution accepts the existing maximum 64-KiB UTF-8 stdin.
Streaming execution still rejects stdin and background mode, as HTTP does.
Background execution is the current retained-image launch contract: no stdin or
command timeout, bounded launch observation and typed launch evidence. A guest
PID is neither final completion nor cleanup authority. Do not add a daemon
supervisor or fabricate foreground Exit from launch acknowledgment.

Console logs are boot/agent diagnostics, not application stdout. Implement
bounded tail/follow and callback behavior with `LogOptions`/`LogResult`, no
reconnect, no implicit start and no absence inference from missing logs. Bind
read access to the approved domain and machine proof; never accept arbitrary host
log paths supplied by a request.

Keep the public `Terminal.Handle`, `Spec` and `Result` contract. Extract the
transport-dependent connection from `Terminal.Server` behind an internal adapter
so HTTP continues using Mint/WebSocket while Port uses correlated native session
messages. Native terminals use the public channel-driven `AgentClient`
interactive APIs, not host stdin, raw terminal modes, signal handlers or access
to the Port's framing descriptors.

Model open/input/resize/close/output/Exit explicitly and bind every message to the
helper epoch and session operation. Preserve single consumer/observer authority,
finite session/idle/attach/close budgets, total input allowance, bounded unread
output and ephemeral closed buffers. The SDK channel/session loop can wait after
input EOF and contains pending queues; API existence alone is not a boundedness
proof. An isolated owned worker and total input credit must bound that whole
pipeline, including SDK queues and collection.

Managed terminals remain retained-image only and hold the existing durable
command slot. Do not add checkpoint/disposable terminals, argv/env options absent
from `Terminal.Spec`, automatic reconnect, session reattachment or input replay.
Keep conservative result classification; only trustworthy native Exit evidence
may complete a session. Connection readiness is not program readiness.

## Volumes and disk growth

Implement managed local volumes under the canonical approved SDK volume root,
with generated IDs, bounded identity metadata and the existing exclusive-root
operational contract. There is no standalone volume manager in the audited
`EmbeddedRuntime`; the HTTP handler performs host filesystem operations.
SmolBox-owned filesystem control is appropriate here, with descriptor/path/UID
checks and an authenticated operation result, rather than invoking HTTP handlers
or adopting arbitrary directories. Reuse public SDK mount structures/attachment
behavior. Do not copy permissive directory modes without checking the dedicated
account's replacement-write and isolation contract.

Preserve independent volume disk reservations, exclusive attachments (including
read-only), Linux restriction and explicit deletion. Machine deletion releases
the attachment, not volume capacity. Unknown deletion keeps the volume reserved.
Native observation must not silently resolve a result that the existing durable
volume workflow treats as unknown. Size remains an admission reservation unless
the host supplies actual quotas.

Managed disk growth remains stopped/created, growth-only and excludes checkpoint/
branch machines, even if the SDK offers live resize. Audit the public SDK resize
path against this stopped-state contract before choosing it; a callable running-
resize API is not sufficient. Use SDK storage APIs without duplicating filesystem
resize algorithms. Reserve increased disk allowance atomically before dispatch,
verify actual geometry, and produce the authorized material transition proof.

## Checkpoints, exports and branches

Preserve each workflow's exact source eligibility, budgets, durable intent,
artifact identity and uncertainty rules. Capture/restore use SDK portable formats
and public checkpoint APIs. Validate runtime/CPU/platform/topology and forbidden
dependencies before publication/activation. Bare idle capture leaves its source
running on success; a normal restore acquires a fresh machine identity. Do not
infer guest idleness or absence of secrets from an empty command slot.

An entered capture without a completed journal proof needs a distinct explicit
resolution, even if the source checkpoint head is unchanged. After verified
worker collection, require a stopped source or the same engine-enrolled live
source with original receipt, SDK PID and OS PID/birth. Bind the original intent,
previous receipt, actual checkpoint head and otherwise unchanged material into
a `CaptureResolutionTransition` using the separate
`smolbox-quiesced-capture-resolution-v1` proof domain. Quiescence applies to the
capture operation; a verified live source keeps running. Advance the ordered material
revision and retire the operation ID, but keep artifact result unknown. Never
decode this transition as capture success or import a staged artifact. Exact
recorded resolution lookup may recover a lost reply without repeating dispatch.
Staging cleanup and reservation release require their own authenticated authority;
source resolution alone does neither. Durable readers and public routing must
support this distinct history before exposing the resulting receipt.

Exports remain stopped-source disk artifacts and registry publication through an
approved destination. Container export excludes `/workspace` as the HTTP endpoint
does. Preserve manifest/resource/environment semantics and exact registry receipt.
The current private `owned-proof` fixture converter is not a product export API.
The SDK exporter can boot an implicit flattening VM; the owner guard correctly
refused that earlier fixture path. Product export must either use public asset/
packer APIs with an explicitly approved bounded host converter, or implement a
fully enrolled/accounted auxiliary VM. Never bypass the guard or turn fixture
success into product qualification. Host conversion tools become explicit package/
setup/provenance inputs if selected.

The engine selects export mode from the verified source record, rather than a
controller assertion. Frozen artifact/staging maxima are upper bounds, not promised
allocations. Bare packing clamps artifact capacity against measured logical disks.
Container helper disks are reserved first; tar and artifact share the remaining
explicit grant. The stream has a finite tar cap, and after the actual layer size
is known the artifact cap becomes the lesser of its frozen maximum and remaining
staging. This avoids an arbitrary fixed split while preserving the aggregate bound.
Legacy fixed-partition records keep their encoding; a distinct optional shared
budget marker requires a reader that understands it before acting on the record.

Branches acquire authenticated source and child intents, stable ordered gates
and the extra backing reservation before dispatch. Public SDK fork APIs need an
owner-context/resource feasibility proof: a forked VMM is not automatically an
enrolled child just because ordinary boot is guarded. Preserve one-leaf/offline/
bare-source limits, hold/release evidence, source dependency retention and explicit
child retirement. A child has its own incarnation/proof; source labels or an
inventory row never supply child authority. Keep uncertain children and backing
allowances until supported reconciliation establishes the required result.

## Qualification and completion

Build a shared behavioral contract suite parameterized by backend, capability,
platform and source kind. Assert the same public result shapes, validation and
dispatch evidence, reservation changes, durable histories, no-replay behavior and
ordinary lifecycle witnesses. Transport framing tests remain separate.

Every operation row and specification row needs a traceable implementation and
acceptance test. Existing offline evidence remains valid only for its exact
packages and scope; it does not qualify changed feature bytes. Add new ordinary
Linux/macOS evidence and current/minimum no-Rust public consumers. Preserve
HTTP-only consumers without native assets and regressions for HTTP/legacy codecs.

Exercise normal completion, explicit API cancellation, normal stop/start, drain,
compatible upgrade and graceful helper/Runtime replacement with a surviving
store. Model unavailable children, lost acknowledgments, interference, corrupt
observation and uncertain durable boundaries in deterministic fixtures.

Do not run abrupt helper/BEAM loss, forced process-loss campaigns, pre-main boot
pauses, watcher failure injection, live persistence interruption or destructive
independent CLI races. No generic runner may resume these implicitly. Supported
normal stop and bounded request cancellation are ordinary APIs, not crash
qualification. Historical fault failures remain unresolved historical evidence.

Parity is complete only when all required rows pass on their supported platform/
source combinations, remaining platform restrictions match the documented HTTP
contract and no feasible feature is silently deferred. A blocker is recorded as
pending with its exact API constraint. Rustler/Kubernetes implementation, crash
qualification and native distribution signing/provenance/license approval remain
separate milestones. Nothing in this design publishes a native package.
