# Clean SDK boundaries for HTTP feature parity

Baseline: SDK 1.22.0, revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. The active and comparison SDK trees
were checked against the complete source inventory before this audit. No
upstream source changed. This supplements the
[offline boundary audit](clean-sdk-api-boundaries.md) and implements the P0 audit
in the [parity plan](../docs/design/embedded-port-http-parity-implementation-plan.md).

The [checked coverage manifest](../docs/design/embedded-port-http-parity-coverage.json)
contains all 37 operations/43 signatures and eight specification features.
`test/unit/backend_parity_coverage_test.exs` compares it with actual backend
operations and adapter advertisement, validates feature references and prevents
completion claims while acceptance/evidence remain pending. Advertisement is
not behavioral qualification; all expanded feature contracts remain pending.

`tests/clean-sdk-api/src/parity.rs` compiles directly against the verified clean
SDK. Its functions are compile-only witnesses and are never invoked by tests.
Three pure configuration tests exercise public overlay-lineage/mount conversion
and offline port mapping without a database, socket, helper, VM or process loss.
The fixture adds the clean SDK's registry crate as a normal exact-version path
dependency; its source is covered by the same complete inventory.

## API and behavior map

| Feature | Callable unmodified boundary | SmolBox work required before enabling |
| --- | --- | --- |
| Health/capacity/metrics/readiness | Existing engine/domain state, public SDK records; platform/guest observations | Match public types, distinguish reserved/configured/measured data, never mutate SDK through reconciliation or instantiate a manager during observation |
| Inventory/measurements | `SmolvmDb` record APIs and supported state/agent observation | Bounded inventory and actual measurement evidence; no adoption or implicit boot |
| Egress/ports | `MachineSpec::{allowed_hosts,ports,resources}`, `EmbeddedRuntime::set_egress_policy`, public `PortMapping` | Exact network backend/empty offline allowlists, approved publish configuration, durable ports and material identity |
| Startup workload | Public `MachineSpec::to_record` / `VmRecord` fields and SDK runtime startup | SmolBox reserves and commits creation itself; the SDK convenience creator inserts its own record and cannot be called after that reservation. Resolve opt-in inheritance before reservation, bind the resulting record and keep bounded startup/readiness qualification separate. |
| Existing image command context | `RunConfig::in_machine`, `workload::record_mounts_to_bindings`, `persistent_overlay_owner_with_lineage` | Receipt-checked record and observed running socket; preserve clone overlay lineage and runtime guest mount tags, not host paths |
| Buffered stdin | `AgentClient::{vm_exec,run_non_interactive}`, `RunConfig::with_stdin` | Finite protected worker, public UTF-8 limits, SDK reply allocation bounds and explicit dispatch/Exit classification |
| Background launch | `AgentClient::run_background` | Retained-image restriction, bounded launch observation and typed PID evidence; no final Exit or PID cleanup authority |
| Streaming commands/files | Existing SDK streaming and capped atomic transfer APIs | Preserve current collector/credit/leases and extend authenticated context to new source kinds |
| Terminal input/resize/output | `AgentClient::run_interactive_io`, public `InteractiveInput`/`InteractiveOutput` | Isolated owned session worker, bounded total input and SDK queues, finite poll/collection, native terminal connection adapter |
| Console logs | SDK manager's public `console_log` accessor; revision-specific console path under the enrolled domain | Do not construct an SDK manager merely to discover a path; bind a bounded reader to the verified machine/domain, retain missing-log uncertainty |
| Registry preparation/publication | `smolvm_registry::{pull,pull_with_progress,push}`, public `registry_client` and parsed `Reference` | Exact manifest/content identity, protected cache/output, finite request/byte budgets, credentials and destination/TLS/redirect policy |
| OCI image list/pull | `EmbeddedRuntime::{list_images,pull_image}` and public agent APIs | Existing-running-agent preflight; typed image identity, source eligibility and seeds disabled until separately accounted |
| Checkpoint capture/restore | `EmbeddedRuntime::{start_forkable_machine,checkpoint_machine,restore_checkpoint_machine}`, portable checkpoint APIs | Approved bare/offline eligibility, portable/CPU compatibility, material transitions, capture streaming/resources and authenticated restore intent |
| Stopped disk growth | `storage::expand_disk::<Storage/Overlay>`, public disk resolve/open APIs | Stopped/source proof, format/geometry checks, durable increased reservation, SDK record update and authorized material proof |
| Local volumes/mounts | Public SDK record/mount conversion; HTTP volume handler performs filesystem operations directly | SmolBox-owned descriptor-bound filesystem control under exact Linux volume policy, exclusive attachment, mode/UID and unknown-outcome contract |
| Export | Public pack asset collector, SDK `pack_export`/manifest seeding and registry push | Approved stopped source, exact container/bare preservation, bounded tool/auxiliary-VM policy, verified publication receipt |
| Branch/held release | Public `agent::fork::{prepare_fork,prepare_held_fork,activate_held_fork}`, `AgentManager::start_with_full_config` | Source/child identity, ordered gates, child boot enrollment, hold metadata, parent dependency and additional backing reservations |

## Findings that change the implementation

The pinned SDK convenience streaming collector stops at 11 MiB. The public
AgentClient send_raw/recv_raw APIs and official AgentRequest/AgentResponse types
permit explicit bounded streaming without that convenience cap. The engine now
uses those verified types in an unadvertised owned command worker, retaining SDK
frame limits and SmolBox's 16-MiB command bound. Public RunConfig/context APIs
still supply image user/mount/overlay selection. A normal non-VM peer verifies
large environment transmission, pre-Exit output and 12-MiB streaming; public
wire/descriptor/reader activation and ordinary guest qualification remain pending.

The runtime's `command_run_config` and `command_client` are private. There is no
need to copy them or patch their visibility: public `RunConfig::in_machine` and
`workload::record_mounts_to_bindings` supply overlay lineage and guest-side mount
bindings from an already authenticated record. `AgentClient::connect` opens the
already verified socket without an `EmbeddedRuntime` or an attach/boot helper.
The configuration witness proves regular and fork-lineage overlay selection and
read-only guest mount conversion, not live socket authority or command behavior.

`EmbeddedRuntime::resize_machine` reaches `agent::live_resize::grow_disks`, which
rejects anything other than `RecordState::Running`. It therefore cannot implement
the public managed stopped-growth contract. `storage::expand_disk` is callable
for both SDK disk types and delegates to the SDK disk algorithm. The later
engine implementation must inspect format/backing geometry and publish a
verified material transition; the compile witness does not resize any file.

The registry warm handler calls a private `pull_smolmachine` helper. Public
`smolvm-registry` pull/push APIs avoid copying HTTP routing/state while retaining
upstream artifact transport. They are asynchronous and may do cache/resume work;
the native preparation supervisor must preflight manifest size/digest, bound
staging/deadlines and preserve partial/unknown evidence. It must preserve the
HTTP explicit-token private/loopback restrictions rather than treating public
client construction as destination authorization.

The channel terminal API does not use the host tty but clears its socket read
timeout and can wait after EOF. Its receiver/pending writer queues need a bound
on total accepted input and an isolated finite worker lifetime. Closing the
input sender is not a worker collection proof and never a confirmed guest Exit.
The witness checks the public session and resize types only.

Image seeds can invoke a builder executable and retain extra cache/VM resources.
The initial implementation keeps `SMOLVM_IMAGE_SEEDS=0`; direct OCI pulling still
needs approved guest egress. A future enabled seed path requires separate owner
enrollment and resource/cache policy. No CLI builder is authorized by this audit.

`collect_from_vm_assets` may boot a temporary flattening VM. The earlier guard
refusal and private fixture conversion are documented historical evidence, not a
product export proof. Product export must explicitly approve/bound host conversion
or enroll/account the auxiliary VM. The compile witness is not executed.

The runtime convenience fork APIs always release the inherited forkpoint and
offer no held-slot option. Public launch-agnostic `prepare_held_fork` and manager
`start_with_full_config` provide the preparation and guarded subprocess-boot
building blocks; both now have compile-only witnesses. The controller must verify
identity reset before reporting a usable child, leave a held child parked and
apply `activate_held_fork` only for the correlated durable release intent. Do not
use a normal convenience fork to simulate hold after the child was released.

Public fork APIs snapshot/clone and then boot the child. Existing immutable boot
context alone does not enroll an arbitrary child or authorize copied source
labels. The controller must create the child intent, authorize/enroll its exact
name/material, and mint independent proof only after correlated supported state.
Held activation must preserve the durable release intent and version identity.

## Current evidence and remaining gates

The macOS compile-only fixture and its three pure configuration tests pass.
Nine selected Elixir tests pass, including four new parity coverage checks and
the existing backend contract tests. Both full SDK inventory checks pass.
Private compiler logs remain in `.local/http-parity/`; upstream compiler warnings
are unchanged. No helper, VM, registry request or fault campaign ran.

This establishes callable clean-source building blocks and checked scope. It
does not complete P1–P9, approve a changed native package, prove runtime bounds,
or qualify Linux/macOS feature behavior. The remaining gates above belong to
their implementation phases; all parity acceptance/evidence is explicitly pending.
If implementation discovers a boundary that cannot meet the contract, record the
exact blocker and evaluate clean APIs/an official SDK upgrade without patches.
Crash validation remains deferred and distribution approval remains separate.
