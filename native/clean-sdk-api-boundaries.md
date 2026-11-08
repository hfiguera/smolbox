# Unmodified SDK API boundary audit

Migration baseline: upstream `9f446ae00219148ca4a703914f44a8e2fab11655` (1.22.0),
verified through `vendor/source.json`. The active workspace now uses the clean
input, with zero downstream patches. Clean ordinary lifecycle, current/minimum
public consumers and native checks have passed on Linux x86_64 and macOS arm64.
The [current evidence](../docs/evidence/embedded-port-unmodified-sdk-ordinary.json)
separates completed checks from remaining work. The checkpoint sections below are
historical snapshots; their pending statements are not the current status.

The next proposed milestone is [embedded HTTP parity](../docs/design/embedded-port-http-parity.md).
Its [P0 feasibility audit](../docs/design/embedded-port-http-parity-implementation-plan.md#p0-establish-the-parity-contract-and-feasibility)
must extend this boundary map for networking, commands, terminals, images, storage
and saved-state workflows before enabling those features. Existing clean ordinary
evidence qualifies the offline surface, not these proposed additions.

The initial parity API and behavior map is now recorded in
[the dedicated boundary audit](http-parity-api-boundaries.md). Its compile-only
and pure configuration witnesses do not qualify new runtime features.

| Responsibility | Clean source boundary | SmolBox obligation |
| --- | --- | --- |
| Worker connection | Public `AgentClient::connect`, no manager/runtime construction | Connect only to controller-authorized running agent; enforce deadline outside blocking SDK |
| File read | Public `read_file_to_path_capped` | Private bounded spool, exact correlated acknowledgment, public chunk/credit limits |
| File write | Public `write_file_from_reader_with_progress`, `FileWriteMeta` | Verify exact input before SDK entry; a small SDK upload can accept a short reader |
| Source lease | Revision-specific SDK source-lock path, isolated in `sdk_compat` | Nonblocking flock compatible with SDK; retain through I/O and exact worker collection; never double-acquire around lifecycle |
| Disk preparation | Public `storage::seed_vm_mode_disks`, `portable_checkpoint::materialize_pack_layers`, `agent::resolve_disk_image`, `StorageDisk`/`OverlayDisk::{open_existing_with_format,ensure_formatted}` | Approved pack material and sparse geometry; finish SDK formatting before making newly owned backing files private/writable; never forge markers or duplicate disk algorithms |
| Implicit templates | Public `smolvm_pack::assets::find_existing_template` | Audit home/executable plain candidates first, then compressed candidates; prevent fallback |
| Lifecycle | Public `EmbeddedRuntime::{start_machine,stop_machine,delete_machine}` | Shared gate and immediate receipt/material/state checks; exclusive cooperating owner requirement |
| Record inspection | Public `SmolvmDb::get_vm`, dependent clone observation | Receipt/incarnation/PID checks; do not adopt inventory |
| Creation absence | No public non-mutating reservation query | Isolated, revision-specific, read-only SQLite adapter; preserve unknown on any failed proof |
| Boot launch | Existing absolute `SMOLVM_BOOT_BINARY`, child argv `_boot-vm CONFIG` | Immutable epoch launcher/context and synchronous owner check before SDK boot |
| Boot implementation | Public `internal_boot::run` | Guard precedes config/SDK initialization; watcher must survive descriptor closure/sandbox |

The clean source invokes the supplied boot path directly through
`Command::new(&boot_exe)` in `src/agent/manager.rs`. It passes the config as a
separate argument and explicitly forwards library search paths before child
startup. There is no need for an extra upstream argv or spawn callback. The
launcher feasibility gates are executable copy/signature/library loading, private immutable
context verification and ordinary boot through that launcher. No live owner-loss
or watcher-failure qualification is authorized.

These launcher gates now have ordinary Linux/macOS evidence. The owner context,
guard and old-epoch fence also have deterministic contracts. The current helper
uses protocol 1.4 to propagate sticky engine unavailability while retaining the
owner, leases, pending streams and capacity. Current admission allows four file
workers and 64 MiB additional engine staging, alongside the Port's 128 MiB upload
budget and two reserved control workers. Normal collection and modeled failures
do not establish abrupt-owner-loss behavior.

The SDK's `pack_export::collect_from_vm_assets` can internally boot a temporary
VM to flatten qcow2. An early Linux fixture author called it without an enrolled
owner context, and the guard correctly refused boot; authenticated cleanup
restored the baseline. That attempt remains failed historical evidence.
The private bare-VM fixture author now resolves existing disks through public SDK
APIs, converts qcow2 with an explicitly selected approved host `qemu-img`, and
uses public SDK asset collection/manifest seeding/packing for the raw results.
The full receipt, stopped-state check and domain/source locks authorize its inputs;
virtual geometry is bounded and checked. It neither starts a temporary VM nor
adds a product export capability or consumer tool dependency. Ordinary Linux/macOS
snapshot import, neutral startup and retained bare-VM behavior now pass with
exact tool/package hashes. The SDK guard and source bytes remain unchanged.

The template resolver is in `crates/smolvm-pack/src/assets.rs`. It visits both
plain locations before either compressed location. Compressed expansion may write
beside the archive or in the user's cache; preparing a valid home plain template
is required to prevent that fallback. `storage::VmDisk` calls this resolver when
creating disks. Preparing an executable-directory template alone is insufficient.

The SDK database creates `vms(name TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL)`
and `vm_create_reservations(name TEXT PRIMARY KEY NOT NULL, owner_token TEXT NOT
NULL, owner_pid INTEGER NOT NULL, created_at INTEGER NOT NULL)` in `src/db.rs`.
Reservation APIs reap stale records, so they cannot implement observation. Schema
validation and inode/path checks belong in the compatibility adapter.

The compile-only fixture checks the connection, capped transfer, public lifecycle,
boot dispatch, disk seeding and source lease APIs against the clean archive. It
passed an offline macOS arm64 `cargo check` on October 12, 2026, using a private
copy of libkrun. Upstream deprecation warnings were left unchanged. This proves
API availability, not runtime qualification or completion of the worker/launcher
feasibility gates.

Future Rustler initialization remains gated: this SDK uses process environment
for boot/library/rootfs settings. The direct NIF cannot change BEAM environment,
block its schedulers, or establish a second domain owner. The shared engine must
accept a generic owner and executable locator; this audit does not enable a NIF.

## Owner context feasibility checkpoint

The shared `HostContext`, `ExecutableLocator` and `BootLauncher` now capture
transport-independent PID/birth/UID identity and copy approved bytes into an
immutable private epoch path. They do not mutate host environment or initialize
SDK ownership. The launcher reads its own adjacent bounded context, checks the
pre-spawn parent identity synchronously, and starts its watcher before SDK boot.
The watcher uses the same getppid/sleep/exit syscalls allowed by the clean SDK's
Linux seccomp list; its authority does not depend on an inherited descriptor.

Five non-VM tests passed on macOS arm64, including a copied executable's normal
`--list` exit and strict code-signature verification. They also cover changed
bytes, redirected roots, malformed/mutable context, epoch separation and modeled
PID/birth/UID mismatch. No owner was terminated or watcher failure injected.

The helper now prepares the epoch launcher before publishing readiness and calls
its guard before SDK boot. Ordinary VM library loading, Linux copy/loading and
the clean SDK build switch remain pending. Existing public package bytes and
approvals remain unchanged.

## Transfer worker integration checkpoint

The Port bridge now supplies generic verified executable/library/owner context to
the shared engine. File I/O runs in private `--file-worker` subprocesses using
public `AgentClient` methods; no patched socket API remains in engine or bridge
code. Workers never initialize SDK ownership, acquire receipts, or start a VM.
The source lease adapter uses the SDK's known sibling lock path with nonblocking
flock admission; this internal path dependency is isolated in `sdk_compat`.

Admission permits four workers and 64 MiB of engine staging, in addition to the
Port's existing 64 MiB upload staging. Requests/events are limited to 16 KiB,
transfers to 16 MiB, and public chunks to 64 KiB. Local upload inputs are exactly
staged before dispatch. The host deadline covers staging, connection, transfer
and collection. A modeled shutdown policy escalates only against the owned child;
unresolved collection retains all leases/spool admission and disables engine
mutation admission. Public target-status propagation still needs integration.
The controller forwards only acknowledged capped reads under existing credit.
An exit status never supplies guest acknowledgment or implies write rollback.

On macOS arm64, 57 engine, 14 Port and six protocol tests passed, along with six
source-integrity tests and all-target lint checks. Two explicitly selected
non-VM helper tests passed: normal failed connection and binary streamed write/
fragmented capped read using a local upstream-protocol peer. They assert normal
collection without termination requests; source leases survive until collected
results are released. No live owner-loss, crash or destructive CLI race ran.

The SDK build remains patched until assets, lifecycle/absence observation and
boot activation have replacements. Linux checks and ordinary VM/package checks
remain pending. Rustler must schedule the same engine on bounded native executors,
provide finite local upload readers, keep destruction asynchronous and establish
owned child-status interoperability before activation; no NIF is enabled here.

## Approved template preparation checkpoint

The engine now prepares approved account templates under domain ownership before
the Port publishes readiness. Approval comes from verified package descriptors.
Every selectable home/helper/boot-directory plain and compressed candidate must
match its approved digest and byte count; compressed bytes must expand to the
exact plain geometry. Existing ext4 superblock validation bounds filesystem size
by backing size. The installer publishes missing files without overwrite, copies
nonzero blocks sparsely, and retains per-package/domain reference metadata. It
never changes HOME or removes account templates. Fast inode/time/mode rechecks
reject candidate/source changes before creation or I/O/boot activation.

macOS APFS gap extension allocated zeros during the initial fixture. Installation
now punches only verified zero blocks in its private staging inode, bounding
temporary allocation. Unsupported sparse preparation fails before publication.
Package authoring regenerates `.zst` from the resized plain copy; the previous
builder copied compressed input geometry without reconciling it. Existing
approved package bytes and evidence remain unchanged; new builds get new assets.

Three ordinary tests linked to the actual clean SDK resolver passed: plain
home precedence, both plain roots before compressed home, compressed precedence,
missing resolution, ordinary expansion and restart reuse. Five engine contracts
cover sparse install/restart/reference retention, conflict preservation,
redirection and candidate changes, expanded geometry and ext4 bounds. Linux,
ordinary VM consumers and launcher activation remain pending. These checks launch
no VM and run no owner-loss or destructive CLI-race campaign.

## Lifecycle and read-only observation checkpoint

The engine now rechecks receipt, marker, material, dependents, state and actual
PID/birth immediately before ordinary SDK start/stop/delete calls under its
machine gate. Precondition errors remain `NotDispatched`; an error after SDK
entry remains uncertain. No outer source flock is held across lifecycle entry.
No calls to patched lifecycle or absence APIs remain in engine or Port source.
The removed callback-lock tests are replaced with deterministic cooperating-gate
and dispatch contracts. Independent concurrent SDK writers remain unsupported.

Observation adapter version 1 opens an existing inode through a separate
read-only/query-only connection, validates the baseline's 13 explicit schema
objects and user version, and checks SQLite integrity. A deferred transaction
holds a consistent WAL snapshot while host material is checked. It never opens
an SDK writer, creates tables, migrates or reaps reservations. Unknown schema,
missing/corrupt/replaced/redirected/busy DB or sidecars cannot yield absence.
The engine validates existing schemas before ordinary SDK initialization can
silently repair missing tables. Domain binding, directory and lock identities
are rechecked before observations/mutations. A WAL reader does not block an
independent writer; exclusive cooperating ownership is part of the contract.

The ordinary macOS temporary-DB contracts cover exact clean schema, read-only
write rejection, consistent WAL reads, preserved stale/corrupt presence,
unsupported versions/tables/triggers, contention, missing/replaced/redirected
files and initialization without schema repair. No live durable interruption,
external CLI race or process loss is exercised. Epoch retirement/fencing, public
availability propagation, clean build switching and ordinary platform/store
qualification remain pending; this checkpoint is not a completed package release.

## Boot dispatch and epoch fencing checkpoint

The engine publishes a bounded pending boot record before SDK entry. The guarded
child enrolls its exact PID/birth/UID and machine/operation identity after the
synchronous owner check and watcher readiness handshake, before SDK boot config
parsing. The SDK result must match that enrollment before the pending record is
retired. Missing, late or contradictory enrollment preserves uncertainty and
disables new engine admission. SDK errors before spawning may therefore leave an
unresolved attempt; they do not authorize replay or cleanup.

Transfer children enroll before receiving any private request authority. Their
exit status remains owned by the transfer supervisor. Boot collection uses only
the exact enrolled PID and observed birth; there is no unrelated-child sweep.
Related pending/actor evidence prevents a positive creation-absence result;
unrelated live machines do not block that observation. Normal shutdown can seal
an epoch only after all its children and pending attempts are quiescent.

Engine opening fences every prior epoch before SDK initialization. A live old
owner without a closed marker, unresolved dispatch, uncollected child, altered
context, redirected path or unknown entry blocks replacement and preserves the
evidence. Context deletion is limited to authenticated, quiescent epoch files.
An unresolved epoch requires explicit operator reconciliation of authority and
process state; it never permits automatic generation reset or adoption. No
operator repair procedure is qualified by these deterministic contracts.

Four new macOS non-VM contracts passed for pending dispatch, normal closed-epoch
retirement, sibling isolation/status ownership and completed boot enrollment.
The real copied helper also passed an explicit ordinary guard fixture: invalid
SDK configuration returns normally after actor enrollment, without a VM or forced
termination. This proves guard ordering and loader feasibility, not owner-loss,
watcher-failure or sandbox runtime qualification. Source review confirms the
clean SDK closes inherited descriptors and allows getppid, nanosleep/
clock_nanosleep and exit/exit_group. Linux, ordinary VM loading and final clean
package evidence remain pending.


## Partial cleanup acknowledgement boundary

`resolve_partial_branch_cleanup` is a protocol-two Inspect/control operation over
`Engine::resolve_unneeded_partial_cleanup`. It uses original retained terminal
history and positive unused-cache provenance: never enrolled, or the same original
exclusive enrolled cache with neither publication attempted nor acknowledged.
Only its request digest survives handoff; missing files cannot manufacture this
fact or downgrade attempted cleanup. An original terminal owner can finish its
handoff after revalidating its cached intent, original collected manager/actor,
protected terminal proof and unused provenance. Selection and archival use one
material-control reservation at a time under the same absolute budget. No SDK
lifecycle dispatch, namespace adoption, manager reconstruction or removal fallback
is introduced. With an exact original exclusive enrolled-but-unattempted cleanup,
a separate completion may resolve an existing Entered disposal after two fresh
original-context absence/source observations under the retained work lock. It
rechecks cache, collected actor and retained roots immediately before the existing
protected ResolvedAbsent publication; no terminal proof is inferred from empty
inventory alone. The four-descriptor material control preserves one ordinary
observer. Terminal archival follows in a separate control phase. Other absent,
used, shared or crossed contexts retain work and backing.

The independent Rust/Elixir DTO preserves original disposal provenance and cannot
satisfy the existing removal command. Optional `partial_cleanup_resolution: 1`
requires `branches: 1`; it remains structurally known and unadvertised/unapproved
by default. Reserved control/output and exact catalog/context bound this path.
Reader-first stores and public consumption are implemented through selective
v49/v48 histories, fresh source observation and guarded paired commit; backend
inventory remains 60 operations / 66 signatures. Synthetic fixtures, private
actor/cache/file models and in-process peers establish these boundaries, not
ordinary SDK/VM or changed-package qualification. Other partial SDK phases and
ordinary package acceptance remain required. Crash validation stays deferred.
