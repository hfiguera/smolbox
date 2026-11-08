# Embedded Port setup and operation

The embedded Port bridge is available for development through the public
`SmolBox.Runtime` API in this source checkout. There is no published native package.
A separately approved helper runs locally under Elixir supervision. Existing HTTP
workers can be used in the same Runtime.
Rustler is a future additional bridge; Kubernetes is a separate future backend.

HTTP feature parity is in progress on this branch. Its repository
design and implementation plan are `docs/design/embedded-port-http-parity.md` and
`docs/design/embedded-port-http-parity-implementation-plan.md`. These documents do
not establish native qualification. Protocol-2 observations and network/port/
workload creation intent and managed terminals are implemented; other expanded
operations remain pending. Exact new-package ordinary qualification is still required.

Packages declaring `terminals: 1` use owned retained-image PTY workers and a
bounded Port connection through the existing managed `Terminal.open/3` API.
Upgrade every native v17 reader and command-slot transaction before advertising
`native_terminal_sessions: 1`, alongside the ordinary terminal store markers.
Binary consumption credit, finite budgets and collection-qualified Exit preserve
the command slot's uncertainty rules. Unknown sessions cannot reconnect or replay
input; graceful replacement does not restore a live connection. HTTP retains its
Mint/TLS/WebSocket adapter, and `Client.open_terminal` stays HTTP-only.
See [interactive terminals](interactive-terminals.md) for the shared API. One exact optimized macOS package has ordinary PTY and current/minimum public
consumer evidence in `docs/evidence/embedded-port-http-parity-terminal-macos.json`.
Linux, PostgreSQL and broader qualification remain pending; other bytes inherit
no qualification.

Embedded configuration now retains optional source, checkpoint, export, branch
and volume approvals using shared validation. Registering a catalog does not
enable an unsupported helper operation. Health reports distinguish SDK version,
SmolBox engine version and supported feature versions; legacy helpers continue
to advertise their existing offline feature set.

The migration to an unmodified SDK has removed the five active downstream patches
while keeping this architecture. Repository design and implementation notes are
`docs/design/embedded-port-unmodified-sdk.md` and
`docs/design/embedded-port-unmodified-sdk-implementation-plan.md`.
Crash validation stays deferred. Exact engine 0.1.0 clean development packages have ordinary
platform and current/minimum consumer qualification on Linux x86_64 and macOS arm64.
The rebuilt engine 0.2.0 packages require their own ordinary qualification; schema
and deterministic peer checks cannot transfer that historical evidence.
Existing approved patched-package evidence remains
historical and cannot approve their bytes.

## Package and host preparation

The Hex package contains Elixir code. A separately approved native package contains
the helper, libraries, root filesystem, disk templates and manifest. Consumers do
not need Rust. Maintainers build it with `native/package.py` from the verified SDK
source described in `native/vendor/source.json`.

Qualified development hosts are Linux x86_64 with accessible `/dev/kvm` and macOS
arm64 with the hypervisor entitlement. Prepare approved offline `.smolmachine`
artifacts and the manifest's digest-pinned `resize2fs` tool. Preserve asset modes
when extracting (`tar --same-permissions` on Linux). Install at a private absolute
path. Approve the exact manifest digest and its complete identity tuple through
your trusted release channel; computing a digest does not authenticate a publisher.

During the unmodified-SDK migration, newly built helpers prepare approved sparse
plain templates in the dedicated account's `~/.smolvm` before readiness. Conflicting
plain or compressed templates in home, helper or boot directories prevent
activation; they are never overwritten. Keep account templates and their
package/domain references when removing a package. Maintainer package authoring
requires `zstd` to regenerate compressed assets from the resized plain templates;
prebuilt-package consumers do not need it. Existing approved packages retain their
historical behavior and identities until replaced through the migration workflow.

Package rebuilds preserve already approved 1-GiB template bytes when their ext4
geometry matches; rerunning the resize tool can otherwise change the digest even
at the same size. Creation completes formatting through the clean SDK's public
disk API before making newly owned backing files private and writable. Approved
templates remain immutable. Transfer spools use private directories independently
of the account's default umask; only verified owned directories beneath the
enrolled domain may have older readable permissions tightened.

Use a dedicated OS account and the SDK's default data paths. Arbitrary database
paths are unsupported. Persist the stable target ID and domain generation. Initial
enrollment requires explicit `allow_initialize: true`; normal use keeps it false.
Never rotate the generation to repair an error. Do not run independent SDK tools,
another helper, or a future Rustler bridge concurrently against this domain.

`SmolBox.Embedded.Config.new/1` validates explicit package identity, manifest digest,
domain binding, approved artifacts, profiles, capacity and allocation floor.
Legacy packages require offline profiles. A protocol-2 package must explicitly
declare `networking: 1` before an approved NetworkPolicy profile is accepted.
Capacity declarations are admission policy, not host-enforced quotas. The repository
example at `examples/embedded_port/config.example.exs` validates this configuration
without launching a helper. Pass the resulting target in the Runtime `:workers`
list to launch the Port bridge.

## Supported development surface

| Operation | Qualification scope |
| --- | --- |
| Create, inspect, start, stop, delete | Full authenticated creation intent and receipt; name alone never authorizes cleanup |
| Foreground execution | Argument vector, environment, work directory and numeric container UID; observed Exit is authoritative |
| Files | Bounded reads and atomic bounded writes; rejected partial upload leaves existing bytes intact |
| Retention | Exact bytes survive normal stop/start and stopped-helper replacement |
| Cancellation | Stops the request/subscription; does not promise guest process termination |
| Output budgets | Finite output cap and acknowledgement credit; sibling requests remain usable |
| Draining | Worker drain fences new assignments; existing retained commands and lifecycle operations continue. Helper quiescence separately fences mutations during replacement |

Network access, startup workloads, port mappings, interactive stdin, background
execution, host mounts, checkpoint/export and branch workflows are not ordinarily
qualified for the rebuilt package. The VM pack does not accept an explicit guest user; the execution
container's numeric UID is separate. Unknown outcomes must be inspected and
reconciled, never replayed automatically.

## Public application startup

Configure at most one embedded target per BEAM node. The store must advertise
`backend_bindings: 1`, `backend_recovery: 1` and `managed_machines: 1`, with the
matching callbacks. Store negotiation and domain binding happen before helper
activation. A mismatched manifest, domain, handshake or recovery record keeps
admission closed. The HTTP client configuration remains unchanged.

New engine 0.2.0 packages use manifest schema 3 and protocol 2.0. The compiled
policy and Hello bind the SDK version, source revision and implemented feature
versions. Fresh creation includes a journal-bound material proof, and its durable
assignment selectively uses codec v17. Every durable reader and projection writer
must support v17 before activation; the store must additionally advertise
`native_material_proofs: 2`. Memory and the updated PostgreSQL example implement
this capability. The current descriptor adds read-only observations to the
existing lifecycle/command/file features, plus network/port/workload creation
translation. Additional parity features and ordinary acceptance remain pending.

Protocol-2 packages declaring `networking: 1`, `ports: 1` and `workloads: 1`
accept the corresponding existing managed specifications. Approval is per feature;
an older descriptor cannot enable them. Port mappings require `managed_ports: 1`
in the store. Their reservations survive stop, draining and normal stopped Runtime
replacement, and release only after verified deletion. Offline egress can coexist
with inbound ports; the SDK record keeps explicitly empty outbound allowlists.

Set `publish_address:` in trusted embedded configuration to approve the host IPv4
listener address. It defaults to `"127.0.0.1"`; `"0.0.0.0"` requires explicit
configuration. The helper uses that private configuration instead of inherited
publisher overrides. This setting applies to the target, not individual machines.

A startup Workload is immutable, container-only and opt-in. With no Workload the
existing neutral boot remains. Empty entrypoint and cmd inherit both image arrays;
explicit arrays replace both without inserting a shell. Environment overrides
merge with image metadata, nil workdir inherits it, and the image user is retained,
including named users. Only restart never is supported. Running state does not
attest application readiness. These semantics have deterministic contracts;
bounded long-start and actual native guest acceptance remain pending.

Protocol-2 packages declaring `observability: 1` support typed health/capacity,
readiness, Prometheus text, inventory and receipt-bound machine measurements.
Inventory contains no native receipts. Capacity reports running-process
allocations/utilization independently of configured limits and durable
reservations; stopped machines can report zero live allocation while remaining
reserved. Unavailable measurements remain nil. The capacity disk gauge follows
SDK apparent storage/overlay lengths for running machines; Linux machine disk
measurements use allocated host blocks. CPU utilization is sampled and returned
as fractional cores; it is not a guest quota or lifetime billing total.

The package/Hello bind observation bounds: 1024 inventory records, a 25-ms minimum CPU sample interval,
65536 disk entries and depth 32. Inventory uses ordinary byte/event credit and
validates the complete result before returning it. Limit, database and sampling
errors never report successful partial inventory or zero replacement capacity.
The rebuilt package's ordinary platform evidence is still pending.

Packages declaring `compact_creation: 1` additionally bind creation encoding and
larger private record-read bounds. Large workload intent uses at most ten 64-KiB
chunks (640 KiB total) inside the existing 1-MiB request frame; command/file limits
do not change. The original specification remains in durable state. Native decoding
checks UTF-8, counts, lengths, complete consumption and ordinary feature validation
before dispatch. Older descriptors retain their original request representation.

These packages can read up to 8 MiB per database record and 32 MiB per read-only
snapshot so escaped/merged workload metadata does not prevent observation. Public
inventory still caps its complete output at 4 MiB and omits environments and
receipts. Older observation descriptors keep the 256-KiB record/4-MiB snapshot
bounds. Bounded image inheritance is checked separately from public request
override limits; a large inherited environment does not acquire the request's
64-variable limit.

Packages declaring `job_resources: 1` bind engine-wide job admission. File workers
and foreground execution share four work slots; read-only observations have two
separate engine slots. Worker children and private staging remain reserved until
collection. Resource exhaustion reports admission exhausted before guest dispatch.
Unresolved collection retains reservations and closes admission; late collection
does not automatically reopen it. These are engine limits shared by future
bridges, separate from the controller's machine resource declarations.

The Port now schedules read-only health/capacity/metrics/readiness/list/measurements
on two dedicated threads alongside its four work threads. Approved protocol-2
job descriptors reserve two request identities for this lane within the existing
32-request bound; work may retain at most 30 requests. Cancellation and credit
use their independent control path. A blocked work pool therefore cannot consume
the observation threads or every request identity. This has deterministic bridge
evidence; complete interference and native platform qualification remain pending.

The declaration caps worker children at four, aggregate staging at 64 MiB and
parent descriptor reservations at 32, with eight additional descriptors preserved
for control. Existing descriptors are included in OS-limit checks. File workers
guard public SDK calls through a private Unix socket relay: requests are capped at
4 MiB, and response headers must fit the requested output's base64 size plus
64 KiB before the SDK receives them. The relay creates no SDK runtime or VM.
These checks have ordinary non-VM worker evidence; complete long-job, auxiliary,
memory and platform qualification remain pending.

Packages declaring `buffered_exec: 1` with `job_resources: 1` implement buffered
foreground execution, including UTF-8 stdin up to 64 KiB (NUL bytes preserved).
The public managed APIs keep their command, result and approval types. Streaming
stdin and background stdin remain unsupported. The command specification stays
in durable state; a private compact request handles escaped data inside the
existing 1-MiB frame. Older descriptors retain their previous command surface.

An owned worker calls the public SDK on the receipt-verified running agent and
uses the SDK's image user/mount/overlay configuration. It creates no runtime or
VM. Private command metadata is capped at 8 MiB per job and 32 MiB across the
pool; output staging remains within the shared 64-MiB reservation. One deadline
covers preparation, SDK execution, collection and output forwarding. Only an SDK
Completed response supplies a guest Exit. Worker collection, cancellation and
lost acknowledgment cannot substitute for it or authorize replay. Output-limit
or consumer failures retain a real observed Exit when one is available.

Buffered bare/image context and byte fidelity have public-peer and real non-VM
SDK-worker evidence. Ordinary guest qualification, background launch qualification
and ordinary log/platform qualification remain pending.

Packages declaring `streaming_exec: 1` additionally route foreground nil-stdin
commands through an owned streaming worker. The compact request supports the
public 64-KiB argv and all 64 maximum-size environment values within the existing
frame cap. Binary stdout/stderr reach callbacks while the SDK command is running;
an actual guest Exit produces `{:exit, code}`. Callback exceptions detach the
observer while bounded capture continues. A blocked callback remains subject to
the absolute request deadline. Streaming stdin and background remain unsupported.

The shared engine forwards authenticated contiguous output-spool ranges, preserves
the existing aggregate output and job budgets, and retains ownership leases until
the worker is collected. This path uses public SDK raw request/response APIs to
avoid the convenience collector's smaller output ceiling. It creates no runtime
or VM. Public Runtime/codec and non-VM SDK peer checks cover full command inputs,
binary output, pre-Exit delivery and output above that SDK collector ceiling;
ordinary Linux/macOS guest/package qualification remains pending.

Upgrade every native v17 reader before advertising `native_streaming_commands: 1`.
The record format stays v17, but older readers reject expanded nil-stdin command
intents. Runtime requires this capability before enrolling a streaming-capable
package. Memory and the PostgreSQL example advertise it after the reader upgrade.
Older descriptors retain their original command limits and store requirements;
HTTP records and v16 are unchanged.

Packages declaring `logs: 1` implement both Backend.logs arities and
Machines.logs with the existing tail/follow/timeout/output/callback options and
LogResult type. The console is receipt-bound boot/agent diagnostics. Log reads
create no SDK manager, do not boot a VM, take no managed command slot or machine
mutation lock, and change no durable intent or reservation. Missing logs do not
prove machine absence; neither lines nor EOF prove workload success or readiness.

The engine emits complete lossy UTF-8 text lines; Port alone handles framing.
Separate log stream credit preserves empty and NUL-bearing lines across chunks.
Callbacks receive `{:log, line}` synchronously; a failing callback detaches while
capture continues. Follow is bounded by the requested observation deadline and
requires a callback. Snapshot/tail limits are 10,000 lines, 8 MiB of line bytes
including newline accounting, and 131,064 bytes per delivered line, matching the
HTTP SSE frame boundary. Raw incomplete lines stay within 1 MiB.

Each read/follower consumes one shared work slot, two descriptor reservations
and 6 MiB from the existing 32-MiB metadata/buffer pool; command/file limits and
the two observation slots are unchanged. The readonly reader accepts authenticated
owner-controlled SDK directories, including mode 0755, without changing modes.
It rejects redirected, foreign, writable or replaced file/directory identities
and never automatically reopens a changed file. Hosts must protect the dedicated
SDK account's filesystem and log contents. Public peers and native non-VM file
models pass; exact-package ordinary Linux/macOS qualification remains pending.

Packages declaring `background_exec: 1` additionally implement buffered launch on
retained image machines through `Machines.submit/3` and `Backend.exec`. The
command has nil guest timeout/stdin; the profile/request budget bounds launch
observation. A confirmed launch returns `LaunchResult` and durable `:launched`
evidence, releases the managed command slot and preserves the machine's resource
reservation. Streaming background execution and launch callbacks reject before
dispatch. PID acknowledgment proves neither readiness nor continued life and
authorizes no PID-based termination or automatic replay.

The owned worker retains shared job/metadata leases and uses public SDK
run_background with receipt-bound image user/mount/overlay context. Zero/malformed
PID, excessive acknowledgment, lost/retired proof and foreground/file outcomes
cannot confirm launch. Ordinary non-VM SDK checks and public Runtime/codec tests
cover these distinctions; ordinary Linux/macOS guest qualification remains pending.
Every store reader must support the native launch combination before advertising
`native_background_launches: 1`. Runtime rejects a background-capable package
before enrollment when this capability is missing. Memory and the updated
PostgreSQL example advertise it; material-reader version 2 alone is insufficient.

To retain an older protocol-2 package, explicitly pass its trusted policy's SDK
descriptor as `sdk_identity:`. The library accepts only implemented feature
versions with the mandatory core contract; approval cannot enable a planned
feature. Package/Hello/limit agreement remains exact. Legacy 1.3/1.4 packages
keep their original observations and capability surface.

Store readers also recognize selective v18 native growth histories and grown
retained-command authority. Install every reader/resource writer before a future
growth descriptor is approved; stores must advertise `native_disk_growth: 1`
alongside `managed_disk_expansion: 1`. Existing HTTP/v16/v17 records retain their
encodings and nil proof defaults. This is a reader foundation: public embedded
growth remains disabled pending remaining disk-format/source and exact-package
platform qualification. Wire dispatch, completed-proof lookup and explicit
operator qualification now exist. A read can use a completed link to inspect the new receipt, but only explicit
quiesced resolution commits an unknown expansion's history. Missing proof and
current target-size inventory cannot authorize growth or release its reservation.
Explicit native stopped resolution pins/quiesces the owner and verifies the
original saved geometry after operator repair; it may publish an engine proof,
but never resizes disks, changes SDK metadata or overrides retained work fences.
Older entered journal entries without an original witness remain blocked.

Previously approved engine 0.1.0 manifest schema 2 binds protocol 1.4 and SmolBox's ownership, observation,
worker, asset and boot-guard policies. The bridge requires at least 4000 ms of
cancellation grace for protocol 1.4 and 2.0 (the default). An epoch-bound unavailable
notice closes work admission while retaining the current helper, pending results
and reserved capacity. Protocol 2.0 keeps approved bounded health, capacity,
metrics, inventory and measurement observations available on that same live
channel; retained machine locks still conflict and readiness stays unavailable.
Observation does not restore work admission, initiate replacement or prove
cleanup. Protocol 1.4 retains its original rejection of new requests. Approved
legacy schema 1 / protocol 1.3 packages retain their original handshake limits;
legacy assignments keep codec v16. Receipt and protocol versions cannot be mixed.
A protocol-major migration requires draining, deleting verified owned assignments
and releasing their dependencies before approving the new package; it cannot
promote old receipts or adopt old inventory. Stopped compatible replacements
within the same protocol preserve the full receipt and domain generation.

For local development, with `target` returned by the configuration example and
an explicitly configured artifact store:

```elixir
children = [
  {SmolBox.Store.Memory, name: MyApp.Store},
  {SmolBox,
   name: MyApp.Runtime,
   namespace: "myapp",
   mode: :ephemeral,
   store: {SmolBox.Store.Memory, MyApp.Store},
   artifact_store: artifact_store,
   fingerprint_key: fingerprint_key,
   workers: [target]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Use a 32-byte fingerprint key. A durable application must preserve that key and
its native domain binding, use a durable store implementing the required callbacks,
and select `mode: :durable`. The PostgreSQL example adapter supplies these
capabilities; apply all its migrations before startup. Memory is explicitly
**ephemeral**: losing it loses ownership and cleanup authority while VMs may remain.
Restarting only the Runtime with its store alive preserves that authority.

Submit work through `SmolBox.submit/2`; retained machines use `SmolBox.Machines`.
Wait for the worker to report ready before exercising lifecycle operations.
`SmolBox.drain_worker/2` stops new assignments. Inspect `worker_maintenance/2`,
finish or delete retained machines, then use `resume_worker/3` with the reported
control version. A retained reservation keeps maintenance blocked until deletion.

The [runnable repository example](https://github.com/hfiguera/smolbox/tree/embedded-port-design/examples/embedded_port)
uses only public lifecycle APIs. It checks disposable execution, byte-exact binary
files, commands while draining, a normal Runtime restart with its store alive,
versioned resume and final deletion. From the repository root, set the five approval
environment variables described in its README and a fresh private run directory:

```sh
export SMOLBOX_EMBEDDED_RUN_DIRECTORY=/absolute/new-run-directory
MIX_ENV=prod mix run examples/embedded_port/scripts/run.exs
```

The example saves a safe `evidence.json` and private encoded authority records.
Those records contain receipts and must remain private; they are forensic evidence,
not a durable store or an automatic restore mechanism. A failed attempt is not a
pass. Preserve its state and reconcile authentic owned records before retrying.

## Maintainer qualification

For an approved package, fixture and already enrolled domain, run the repository
proof with absolute paths:

```sh
MIX_ENV=prod mix run scripts/embedded-port-proof.exs --ordinary \
  --package /absolute/package --fixture /absolute/offline.smolmachine \
  --sha256 APPROVED_FIXTURE_SHA256 --domain-json /absolute/domain.json \
  --output /absolute/new-evidence-directory
```

This internal qualification harness is not a public application startup example.
Keep receipt-bearing evidence private. A failed attempt is not qualified: preserve
its evidence and reconcile authentic owned state before retrying. Ordinary mode
avoids deliberate helper/BEAM interruption. Historical patched-package Linux
boot/helper-loss and macOS durable boundaries passed; they do not qualify clean
packages. Live crash and independent CLI-race campaigns remain deferred at the
user's request. See the latest
repository progress record (`docs/design/embedded-port-progress.md`) for exact scope and failures.

Default `mix test` and `mix ci` exclude both `runtime` and `deferred_crash`. The
second tag separately fences native owner/helper-loss and persistence-interruption
fixture tests. Selecting ordinary runtime qualification does not select deferred
crash cases. These cases remain deferred; use deterministic models and normal
shutdown/replacement for current validation.

## Upgrade and drain procedure

Quiesce the target, finish subscriptions and reconcile pending outcomes. Unknown
reservations block completion. Stop retained VMs normally, close the helper, retain
old assets, and preserve the enrolled generation and authentic receipts. Approve
the replacement manifest, inspect retained state, then activate the matching epoch.
Never reinterpret a foreign row or mint ownership from an inventory result.

Historical four-patch to five-patch package upgrades preserved data on both platforms.
The [clean-package evidence](evidence/embedded-port-unmodified-sdk-ordinary.json)
records explicit compatible clean helper replacements, retained data and owned
cleanup on both platforms. These are specific approved package pairs, not automatic
public store rebinding or patched-receipt adoption.
It does not qualify arbitrary firmware changes or rollback. Native store encoding
is selective version 16; legacy HTTP encodings remain supported. Upgrade every
reader before persisting native records. Compatibility with old HTTP records does
not make an old reader safe for native records, and helper rollback does not prove
store-codec rollback.

The workspace now builds against verified unmodified SDK source. New clean
packages require their own exact approvals; ordinary platform/consumer qualification
for the recorded clean packages is complete. Further changed bytes need new checks;
the four-patch/five-patch results above remain historical. Follow the
repository migration design (`docs/design/embedded-port-unmodified-sdk.md`) and
progress record (`docs/design/embedded-port-progress.md`). The migration keeps Port and
HTTP supported, with Rustler and Kubernetes reserved for later implementation.

For patched-to-clean migration, drain and delete owned machines through their
original approved package, preserve authority/history and enroll a fresh clean
target/domain, preferably under a fresh dedicated account. Direct adoption of
patched-package receipts is outside scope. Unknown reservations block migration;
never relabel assignments, rotate their generation or remove unresolved evidence.
The unmodified SDK requires one cooperating owner for the dedicated domain;
independent SDK/CLI writers and simultaneous Port/Rustler owners are unsupported.
Crash and destructive CLI-race validation remain deferred.

The public development flow is covered by ordinary lifecycle qualification.
The [clean public Runtime evidence](evidence/embedded-port-unmodified-sdk-ordinary.json)
records platform/toolchain identities, failures and cleanup; prior patched-package
evidence remains historical. Production crash
qualification and distribution approval still require the
deferred live fault gates, independent CLI races, exact binary/source and license
delivery review, and publisher signing/provenance. No package is published by
this implementation. The repository release gap assessment is
`native/release-review.md`.

Store readers also recognize selective v19 typed native OCI and registry creation intent and
retained image-pull records. Upgrade every reader and reservation writer before
advertising `native_sources: 1`, alongside `registry_sources: 1` and
`managed_images: 1` for image operations. Memory and the updated PostgreSQL example
include this reader marker. Existing HTTP and v16-v18 native records keep their
encodings. A source manifest identity cannot replace local pack content authority.
OCI catalog/assignment translation and protocol-2 creation, qualification,
absence and source-bound startup routing now exist behind explicit source approval.
Reader support does not activate them. Public image/source capabilities remain
disabled while remaining credential/source combinations and ordinary exact-package
qualification are pending.


Registry preparation now has a gated embedded adapter and typed
`ArtifactPreparation` translation. It selects an exact approved registry source
and explicit `RegistryPolicy`, bounds its reply and preserves distinct manifest
and content digests. The engine verifies downloads and rehashes warm entries;
a preparation observation still grants no machine ownership or readiness.
Current package policy keeps remote_sources disabled. The gated create_prepared adapter now validates exact preparation/source identity
and routes cached creation without refetching. Registry intent preflight checks
policy/template feasibility before reservation; pack bytes are checked during
creation. Scoped credential options now travel through bounded private Port IPC only for
preparation; exact configured token realms govern exchange and bookkeeping strips
tokens. Cached creation validates options but does not refetch or transmit tokens.
Live authenticated exchange and ordinary exact-package Runtime/materialization
qualification remain pending before this becomes an admitted public workflow.
