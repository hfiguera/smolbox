# SmolBox native workspace

The embedded Port backend supports explicitly approved development packages.
The workspace builds against an unmodified SDK. Exact engine 0.1.0 packages have
completed ordinary development qualification on Linux x86_64 and macOS arm64;
an exact rebuilt Linux 0.2.0/protocol-2 package now has
[ordinary lifecycle, observations, current/minimum public consumers, terminal and compatible-upgrade evidence](../docs/evidence/embedded-port-http-parity-linux-ordinary-0e35c3f.json).
Expanded feature, durable-store and changed macOS package qualification remain pending. Follow the
[migration design](../docs/design/embedded-port-unmodified-sdk.md),
[implementation plan](../docs/design/embedded-port-unmodified-sdk-implementation-plan.md),
and [progress evidence](../docs/design/embedded-port-progress.md).
The [clean-package ordinary evidence](../docs/evidence/embedded-port-unmodified-sdk-ordinary.json)
records lifecycle, current/minimum public consumers, PostgreSQL Runtime replacement,
compatible helper replacement and bare-VM snapshot imports on both platforms.
The [completion audit](../docs/design/embedded-port-unmodified-sdk-completion-audit.md)
maps every plan item to implementation and evidence. Historical patched-package
and live fault evidence is separate.

The owned Port process sets umask 077 before SDK work and threads, so fresh
SDK directories and files are private even with a shared-group caller default.
The shared engine leaves process-wide umask control to the bridge; a future
Rustler bridge must preserve BEAM process settings.

The shared engine has a separate pre-handoff branch collection control on the
original `RetainedBranchResolution`. It requires the full frozen creation, a
distinct action and explicit quiescence. It can collect the original returned
manager/enrollment without inventing initialized readiness, deletion or backing
release. Its synchronized cleanup fence preserves earlier lifecycle bytes and
blocks further initialization/release/restart. The original work and backing stay
charged; a four-descriptor material-control allowance leaves one observer available
under full branch preparation admission. [Deterministic evidence](../docs/evidence/embedded-port-http-parity-partial-branch-collection.json)
is separate from SDK/package qualification. Its later protocol-two
`collect_partial_branch` boundary now checks exact approval, source domain,
full-request/proof correlation and package platform, with no streams and one
30-second control deadline. The engine proof keeps its original persisted bytes;
platform is reply metadata. [Port models](../docs/evidence/embedded-port-http-parity-partial-branch-collection-port.json)
launch no SDK or VM. Durable/public integration, explicit partial-child disposal
and ordinary changed-package qualification remain required before native branch
admission can activate.

The protocol crate builds independently of hypervisor assets and implements
bounded framing, [versioned DTOs and admission/credit state](smolbox-protocol/README.md).
Protocol-2 packages declaring `streaming_exec: 1` expose the owned streaming
command worker through compact input and byte/event-credit output. Public nil-stdin
command bounds and actual Exit evidence are preserved; stores must advertise
`native_streaming_commands: 1` after upgrading all native v17 readers. The
transport-independent engine remains reusable by a future Rustler bridge.
Broader streaming guest/platform qualification remains pending.

Protocol-2 packages declaring `terminals: 1` route managed retained-image terminal
sessions through the shared engine and an owned `run_interactive_io` worker.
Protected private IPC authenticates the parent, metadata and operation identity.
Machine/source/domain leases and shared resource reservations remain held through
exact child collection. Unknown collection retains leases and quarantines
admission; EOF, local close or cancellation cannot substitute for guest Exit.

Packages explicitly declaring `terminal_preflight: 1` (which requires
`terminals: 1`) additionally support receipt-bound, read-only terminal image
eligibility. The shared engine uses a bounded SDK-record read and observation
admission, with a 30-second ceiling enforced in the engine and wire. It allocates
no terminal worker, spool or PTY and does not start a stopped VM or probe its
agent. Stopped eligible images pass, matching HTTP preflight. Bare, branchable,
held, missing and foreign records fail before terminal dispatch. The returned
connection source keeps the original owner/epoch and remaining absolute budget;
opening still independently checks authority and machine state. Existing
terminal-only descriptors retain their original opening path and do not gain
this capability implicitly. The new source needs ordinary changed-package
qualification; historical terminal/growth evidence does not cover its bytes.

The Port adapter forwards initialized/output/input/resize/close events with finite
budgets and bounded queues. Worker initialization does not prove guest readiness.
Only whole consumer removal restores output credit. Neither the bridge nor the
store persists a transcript, connection or input for replay. SDK I/O uses the
bounded existing-agent relay, without a host tty or signal handler.

Stores must advertise `native_terminal_sessions: 1` after all native v17 readers
and command-slot transactions are upgraded, alongside ordinary terminal markers.
The exact Linux package in the ordinary evidence passes current/minimum no-Rust
public consumers and ordinary PTY checks. Changed macOS packages, native
PostgreSQL and broader terminal resource/interference qualification remain pending.
Public Runtime peers and non-VM SDK/child checks are separate scoped evidence;
they do not transfer historical platform qualification.

`smolbox-engine` consumes the exact source pin and implements
prepared creation, intent-bound absence checks, receipt-checked observation/lifecycle, and bounded foreground
exec normalization, and capped guest file transfers. Earlier 0.1.0 packages
have macOS proof evidence. The [framed helper](smolbox-port/README.md), internal Elixir Port owner and
record-scoped adapter have also run macOS proofs, including encrypted PostgreSQL
recovery across fresh BEAM processes. Pack structure and geometry are validated
before reservation. Public development admission is available; distribution approval
remains separate.
HTTP-only Elixir consumers do not build this workspace or require Rust.

The maintainer package-consumer check can also exercise an already built, signed
helper from a fresh production application. Use a PATH containing the selected
Elixir/OTP toolchain, Python for inventory evidence, and ordinary OS tools, with
no `rustc` or `cargo`. `--without-rust` verifies those executables are unavailable
both in the maintainer and consuming application. It compiles only the extracted
Hex archive and production dependencies. Native assets remain a separately
approved local package; they are absent from the Hex archive.

```sh
elixir scripts/ci.exs package-consumer --without-rust \
  --native-public \
  --report /new/consumer-report.json --package-output /new/smolbox.tar \
  --native-package /approved/local/package \
  --native-fixture /approved/container.smolmachine --native-sha256 APPROVED_DIGEST \
  --native-domain-json /enrolled/domain.json --native-output /new/native-proof
```

Add `--native-terminal` with `--native-public` for the ordinary retained-image
PTY qualification on packages declaring `terminals: 1`. It verifies binary
input/output, resize, observed Exit 7 and durable slot release. The native package
must use an optimized release build so complete template verification fits the
finite startup budget.

Run under the minimum supported Elixir/OTP toolchain with `--minimum` to pin
minimum production dependencies, optionally consuming the same `--archive`.
Omit all `--native-*` options for an HTTP-only consumer with no native assets.
Reports include the archive digest/file inventory, dependency versions,
toolchain, proof-tool digests and exact helper identity. `--native-public` uses
the public managed Runtime example: execution, binary files, draining, normal
Runtime restart with its store alive, versioned resume and owned cleanup. Private
encoded authority records remain under the new output; its sibling `.log`
preserves bounded diagnostics on failure. Output reuse is refused. Public mode
does not qualify live crash boundaries or distribution signing/source delivery.

`--native-ordinary` stops the owned VM before graceful helper shutdown and tests
retained data through a fresh Port epoch. It never runs the owner-kill or deadline
fault segment; the report declares interruption and crash qualification false.
Every native consumer must explicitly select `--native-ordinary` or
`--native-public`; omission is rejected before native work. Direct internal Port
proofs also require `--ordinary`. Public and internal ordinary modes are mutually
exclusive. The ordinary mode
does not count as evidence for the deferred interruption gates.

The shared Python ordinary runner uses EOF and bounded normal collection on
failure; it never escalates to killing the helper. Unresolved shutdown records
private diagnostics and preserves intent/receipt/epoch evidence for explicit
reconciliation. A diagnostic PID is never deletion authority. Ordinary runners
clear inherited loader injection/override variables before package startup.
Compatible clean upgrades require the same policy; patched-to-clean upgrades
cannot carry old receipts through this proof.

```sh
python3 native/bootstrap.py
cargo fmt --manifest-path native/Cargo.toml -p smolbox-engine -p smolbox-protocol -p smolbox-port --check
bash native/check.sh
cargo clippy --manifest-path native/Cargo.toml --all-targets --locked -- -D warnings
```

Ordinary worker fixtures in `check.sh` use the optimized helper. A Linux debug
executable can exceed the existing 256-MiB executable-admission bound; use the
release helper for explicit worker fixtures rather than increasing that bound.

Native dependency resolution is recorded in `Cargo.lock`. Keep the research
checkout under `external-references/` read-only; native integration must use the
exact declared upstream revision and complete unmodified inventory.

The full pinned smolvm dependency includes its HTTP and CLI dependencies; it does
not offer a slim embedding feature. The verified offline
[source snapshot](vendor/README.md) matches upstream bytes and modes without
patch application, a fork or source rewriting. Bootstrap requires Python 3.12+.
The [removed patch history](upstream-patches/README.md) remains in Git. A locked
protocol-only test can run without hypervisor libraries after bootstrap:

```sh
cargo test --manifest-path native/Cargo.toml -p smolbox-protocol --locked
```

On macOS, native compilation needs libkrun. When using `LIBKRUN_BUNDLE`, point it
at a private **copy** of the chosen libraries: the upstream build script rewrites
install names and signs that directory. Never point it at the research checkout
or an installed runtime used by another process. These build checks do not prove
that the resulting executable can launch a VM or is correctly entitled/signed.
`LIBKRUN_BUNDLE=/approved/runtime/lib bash native/check.sh` runs the integrity,
Rust test/lint and documentation checks using a private copy of the libraries.
During the unmodified-SDK migration, `native/check.sh` selects ordinary library
and binary tests plus the normal child-reaping integration check. The
patch-specific historical parent-loss campaign has been removed from the active
tests. Do not use an unfiltered workspace test command to resume deferred fault
qualification.

The script also builds the helper and selects a reviewed list of exact ordinary
worker fixtures. Its sparse-file growth fixture covers raw and QCOW geometry,
native acknowledgment and lease retention through normal child collection,
without opening a VM or SDK domain. This is not public stop-grow-start
qualification. The `ordinary_boot_guard` fixture uses invalid SDK
configuration, establishes enrollment before SDK parsing, and exits normally.
Worker fixtures use private IPC and a local agent-protocol peer without a VM,
forced termination or SDK domain initialization. Generic `Engine::open` is
for lifecycle/observation; file operations require `Engine::open_with_host` with
verified executable and library paths. The Port supplies that context. Transfer
supervision retains leases until exact child collection, bounds four workers and
64 MiB of additional engine staging, and rejects further engine mutations if
collection cannot establish quiescence. See the
[boundary audit](clean-sdk-api-boundaries.md) for migration status and Rustler gates.

It also builds an independent fixture against the verified clean SDK and checks
the real template resolver using temporary home/executable files. Maintainer
package authoring requires `zstd` to compress the resized approved plain templates.
Consumers use prebuilt packages and do not need that tool. Before publishing
readiness, the helper installs missing approved plain templates in the dedicated
account's `~/.smolvm`, refuses any conflicting selectable candidate, and records
package/domain references. It rechecks asset identities before activation and
never overwrites conflicts or removes shared account templates. Native callers
must call `Engine::prepare_templates` before creation or activation.

The explicit `owned-proof` example provides a self-booting native qualification
tool, not an application interface or the framed Port helper. Its `fixture`
command packs a local Alpine runtime rootfs into an offline image without a
registry, directly at the supplied artifact path; it creates no launcher stub.
The bare-VM `vm_pack_proof.py` campaign also uses its `vm-seed` / `vm-export`
fixture commands. For qcow2 source disks, explicitly pass `--qemu-img /approved/host/qemu-img`
to the Python runner. That private authoring tool converts stopped receipt-bound
inputs under the source/domain locks and uses the SDK's asset collector/manifest
seeder/packer. It never invokes the SDK's temporary export VM or bypasses the boot
guard. This is a maintainer fixture prerequisite, not a native consumer dependency
or a product export capability. Raw fixtures require no converter.
`prove` saves creation intent and receipt, boots neutrally, checks
applied resources and exec options, exercises a deadline without Exit, transfers
a capped file, checks retained stop/start, and deletes only that owned receipt.
Failure retains evidence/storage; `cleanup RECEIPT_JSON` is explicit and cannot
mint ownership from inventory. See the progress record for actual platform
evidence. Run native proofs only with approved assets and an explicitly selected
account/domain; the ordinary test suite launches no VM.

The explicit `smolbox-port/tests/fault_proof.py` helper-loss proof is restricted
to the non-root account inside the disposable `smolbox-nested` Linux lab. It kills
only its live `Popen` helper, checks the previously observed VMM PID/start identity
has exited, and preserves the full creation receipt across a fresh helper epoch.
It covers idle helper loss, loss before command send, loss after acceptance and
loss after an actual stdout witness. Explicit replacement commands inspect a
persistent counter; stopped full-receipt deletion must restore the empty inventory.
Failures preserve the intent/receipt for explicit fixture maintenance. This raw
protocol proof does not qualify durable-store accounting, observer cancellation,
boot-time parent loss or the complete fault matrix.

The removed patch-specific boot fault fixtures remain in Git at
`4be5e7b:native/smolbox-engine/tests/parent_watch.rs` and
`4be5e7b:native/smolbox-port/tests/boot_fault_proof.py` (with its shim). They rely
on old SDK hooks and do not qualify the SmolBox-owned guard. Fault tests for the
clean architecture require fixtures for its owner guard.

For normal VM validation without deliberate interruption, use
`smolbox-port/tests/ordinary_proof.py` with `--package`, `--fixture`, `--sha256`,
`--domain-json` and a new `--output` directory. It checks actual execution/resources,
numeric non-root UID, binary file transfer, retained stop/start, normal shutdown
of a helper whose VM is already stopped, fresh-helper reopening and full-receipt
deletion. It preserves the initial inventory and records the exact package tuple.
Its report explicitly leaves crash handling unqualified. This is a separate
validation scope; it does not replace or weaken the fault-proof expectations.

Add `--observability` only with an isolated empty SDK inventory. It binds health,
capacity, Prometheus gauges, readiness, streamed inventory and receipt-bound
measurements to the actual empty, stopped, running and deleted lifecycle states.
It repeats the stopped observations after graceful helper replacement. Running
CPU/RSS samples must exist; stopped or missing process counters must remain
unavailable. These read-only results never provide creation or deletion authority.
The optional checks add no deliberate process-interruption campaign.

Add `--upgrade-package /approved/new/package` to exercise a different compatible
package after stopping the VM and closing the original helper normally. Both
packages must retain the same platform, architecture, engine version and SDK
revision. The proof keeps the original full receipt/domain generation and old
assets, then verifies retained data and deletion through the new helper. This
tests the specific package pair; it does not approve arbitrary upgrades or codec
rollback.

In the disposable Linux lab, `--child-reaping` observes all helper-thread child
lists after three normal VM stops and requires them to become empty. The separate
Rust reaping contract releases subprocesses through pipes and checks that the SDK
collects registered children while an unrelated sibling's exit status stays
available. Neither check introduces process-interruption faults.

The opt-in Linux `smolbox-port/tests/network_fixture.py` supplies two reachable
local TCP responders in an explicitly created loopback-only network namespace.
Run it through `sudo unshare --net`, followed by `-- /usr/sbin/runuser -u lab --`
and the unprivileged proof command. Setup verifies the disposable lab host and
isolated namespace, then passes its identity to the child. The SDK never runs as
root. `network_proof.py` requires an approved Python container sidecar, the usual
package/fixture/hash/domain/output arguments, an explicit `--host-port` and
`--isolated-lab-network`. It checks offline-with-mappings and a one-address CIDR
policy, independently reachable positive controls, inbound replies, loopback-only
listeners, two stop/start cycles, exact child collection and owned deletion.
It preserves authentic receipts on failure and closes helpers normally.
This raw proof does not qualify managed store reservations or startup workloads.

The data-only `prepare_network_fixture` engine example builds the Python fixture
through public SDK `AssetCollector`/`Packer` APIs. Its five arguments are the
approved donor sidecar, donor SHA-256, approved package directory, package-manifest
SHA-256 and a new output path. It verifies those inputs and carries the unchanged
OCI layers in their original order into current approved runtime assets. It
records upstream layer labels separately from uncompressed-tar content hashes.
Storage/workspace/checkpoint state is excluded from this test fixture. Preparation
opens no SDK domain, starts no VM and changes no upstream source. Keep generated
sidecars and raw proof records private. The public consumer network mode is
documented in `scripts/ci/README.md`.

The data-only `prepare_bare_fixture` example takes an approved package directory,
its exact manifest SHA-256 and a new output path. Use the release profile. It
verifies every declared asset before and after packing, then uses the unmodified
SDK `AssetCollector`/`Packer` APIs to carry the approved agent rootfs and empty
storage/overlay templates into a VM-mode sidecar. Host/guest platform metadata
comes from that package; preparation need not run on the eventual guest host.
No inline libraries, OCI layers, workspace seed, credentials or captured state
are included. It opens no SDK domain/manager and launches no guest or package
executable. Footer/CRC checks and the whole-file digest qualify the prepared
input only; boot, filesystem growth, capture and branch behavior require their
own ordinary acceptance. Generated artifacts and raw records stay private.

An optional sixth argument supplies bounded JSON image defaults for a controlled
startup-workload fixture. `smolbox-port/tests/workload-defaults.json` records a
literal argv, inherited environment, working directory and named root user in a
guest marker, then exits with status 7. The producer reports the defaults file's
SHA-256 separately. This changes test metadata only; the donor's OCI layers and
the approved runtime assets remain unchanged. The separate public consumer
`--native-workload` mode checks omitted, inherited, overridden and missing
startup commands across normal stop/start and stopped Runtime replacement. It
observes VM state and console logs without attesting application exit status or
readiness. Run this opt-in mode only in the same disposable isolated Linux lab.

`scripts/embedded-port-proof.exs --ordinary --operations` adds finite live Port
checks for explicit caller cancellation, another VM's execution, command/file
byte limits, incomplete-upload cancellation, slow-consumer credit and epoch
quiescence. Use it only in the disposable Linux lab. It sends no process signals
and makes no claim that cancellation terminates a guest command. The separate
Linux-only `interference_proof.py` checks changed material with copied labels,
corrupt rows, a held SQLite write transaction and same-name recreation. It
restores only its own saved row and deletes through authentic receipts; it does
not qualify independent CLI races or process-loss behavior.

`cli_interference_proof.py --cli /approved/smolvm` exercises a separate unpatched
SDK CLI changing CPU material on the proof's stopped fixture while the helper
is active. Native inspection/deletion rejects the changed material despite
preserved labels. The CLI restores that one setting, then authentic native
cleanup restores the empty baseline. This finite case does not qualify
destructive concurrent races. `package_metadata_proof.py` replaces only private
copied license/source files and verifies framed preflight rejection with no VM
boot or modification of the original package.

See [the public setup guide](../docs/embedded-port.md) for the admission boundary
and [the distribution review](release-review.md) for signing/source-delivery gaps.
The builder hashes copied license/source metadata as package assets. Its explicit
macOS `--signing-identity` path still needs an actual distribution signer and
qualification of the resulting signed package; default signing remains ad-hoc.

The builder now adds `agent-rootfs.tar` from its owned rootfs copy, excluding
runtime readiness markers. Tar entries preserve guest file/link/mode semantics
with normalized root ownership and timestamps, fixed ordering, finite count/byte/
time limits and independent input-version checks. The tar digest/size/mode enters
package approval. Linux bundles lacking the SDK packer's `libkrunfw.so.5` name get
an independent byte-identical copy of the packaged `libkrunfw.so`; an existing
versioned file is preserved. The input runtime assets are never changed.

The helper selects export asset grants only from the verified manifest. Shared
engine setup binds them to package, domain and library root under native admission;
packing rechecks the files under the retained whole-job budget. Packages without
the tar retain their previous setup path and cannot provide that pack catalog.
The default Linux and macOS packages advertise exports after ordinary bare
and container qualification. Both platforms have minimum-toolchain PostgreSQL
qualification. The opt-in
`ordinary_manifest_rootfs_archive_matches_approved_guest_files` test checks an
explicit local package's preflight and tar/manifest correspondence without opening
an engine or VM. It does not qualify guest boot, distribution or crash boundaries.

The ignored `ordinary_owned_container_conversion` witness requires a stopped,
Port-owned source in an already enrolled dedicated account. Its explicit
`pipeline` phase uses production qualification and packing for a bare or
container source. The `publish` phase additionally requires one approved
loopback registry destination and its transient bearer on stdin. The test peer
in `smolbox-port/tests/export_registry.py` keeps bounded upload files, enforces
immutable tags and supports independent digest readback. Neither mode changes
public capability admission.

For the managed export proof, use `scripts/embedded-exports-runtime-proof.exs`
inside an installed production consumer with no Rust on PATH. Run it with
`--without-rust --ordinary`, the configured target file, a fresh evidence
directory, the loopback registry address, a private bearer file, and `bare`
or `container`. The target must point to an exactly approved platform package
advertising exports and to an ordinary fixture of the selected mode. The loopback
fixture can allow anonymous reads while requiring the bearer for publication.
The proof publishes and resolves the export, approves the digest-pinned registry
source, then boots and changes the imported copy independently of the original.
It checks final reservation release and leaves the original Runtime available on
a failed run. The default proof store is Memory. Add `--postgres SETTINGS` in
the durable example consumer with a migrated Repo and a JSON settings file
containing the partition and the path to a private 32-byte encryption key in
`partition` and `key_file`. After normal exit, run
`--without-rust --ordinary --readback EVIDENCE SETTINGS` in a fresh BEAM to verify
the exact completed records without attaching a worker.

For offline Linux builds, use the locked Cargo vendor tree with a private
`CARGO_HOME`, a vendored-source configuration and `CARGO_NET_OFFLINE=true`.
Transfer a clean source-only dependency archive. When authoring it on macOS,
`COPYFILE_DISABLE=1 tar --no-xattrs --no-acls` avoids AppleDouble metadata files:
some C dependencies glob every `.c` file and would try compiling generated
`._*.c` metadata. Verify the source, dependency, toolchain and runtime archives
inside the guest before extraction/build. Keep these private inputs and credentials
separate; do not copy a personal Cargo home or modify the sealed lab baseline.

The Linux resource proof checks both 512 and 768 MiB requests and records their
kernel readings. `MemTotal` reports usable RAM, excluding reserved/kernel memory;
its change need not exactly equal the requested allocation change. See the
[kernel documentation](https://docs.kernel.org/filesystems/proc.html#meminfo).
The qualified Linux build reported 525,000 and 783,048 KiB. The proof allows
2 MiB above the first nominal total and requires the second reading to follow the
256 MiB increase within 8 MiB. These are qualification checks for the recorded
build, not host memory quotas or evidence for untested firmware/platforms.

Before opening an engine, its caller must set `SMOLVM_BOOT_BINARY` to the absolute
self-booting executable path, set `SMOLVM_IMAGE_SEEDS=0`, remove
`SMOLVM_BOOT_DEBUG`, and resolve approved assets. The engine refuses inherited
`SMOLVM_DATA_DIR`; `with_db` alone is not an isolated data domain. It holds both
an account-wide OS lock and a persistent default-path domain binding. Opening the
engine is explicit and is not an application-start side effect.

The migration uses per-machine gates to serialize cooperating engine requests and
reject contention before mutation. SmolBox rechecks receipt/material/state/PID
identity immediately before ordinary SDK lifecycle entry. It does not hold an
outer source flock around a lifecycle API that takes its own lock. Commands and
files retain their source lease through I/O and exact worker collection. There is
no atomic receipt check inside the SDK mutation lock against an independent CLI
writer; independent writers remain unsupported. Those earlier SDK callback tests
are historical patched-package evidence, not the new engine contract. A local
incarnation marker prevents ordinary directory recreation from satisfying a
receipt, but is not tamper-proof identity against an actor with the same account's
write privileges. Lost create responses remain unverified; inspection cannot
mint a replacement receipt.

Creation absence uses a separate read-only SQLite connection with adapter schema
version 1, pinned to the exact SDK revision and DDL in `sdk_schema.json`. A
consistent snapshot checks VM rows and every reservation without reaping. Missing,
corrupt, redirected, replaced, busy or unsupported databases fail conservatively.
Existing databases are validated before SDK initialization can create tables.
Domain/lock identity and all local material/handles must also establish absence;
unknown durable reservations are retained on every failed proof. WAL readers do
not exclude independent writers. Epoch fencing and ordinary clean-package recovery
qualification remain part of the unfinished migration.


Image-backed file access activates the existing persistent image root through a
fixed `/bin/true` request in the same bounded file worker as the transfer. It does
not attach another SDK runtime manager. Activation preserves the approved image,
mounts and overlay lineage; it cannot supply arbitrary argv/env/user/stdin. Only
observed normal Exit permits file dispatch. Like HTTP files, activation's program
exit status is discarded. Its output is streamed into a bounded discard sink
with the clean SDK's 11-MiB ceiling, without enlarging public command/file limits. One absolute deadline closes observation
sockets across both phases; the original machine/source/domain leases and the
worker/metadata/descriptor allowance remain held through actual collection.
Bare file access keeps its existing direct agent path. This private worker change
does not alter the public Port protocol or store codec. Exact changed-package
ordinary qualification is required independently of the earlier package evidence.


Mounted files follow the same policy-aware qualification as commands and PTYs.
Use the engine's *_with_volume_policy file methods for signed mounted records;
the original methods reject those records before staging or reading input. The
Port adapter supplies only the configured approved policy. Qualification retains
ordered volume/machine/source authority and promotes one job lease into bounded
file admission, with no second work slot. Full proof and volume gates follow the
worker through collection and acknowledged-read forwarding. Current descriptors
still do not enable volumes; non-VM peer/model checks are not mounted-guest
qualification and changed package bytes need their own ordinary evidence.


Completed volume checks share one backing verifier for inspection, mounted work
and deletion. Only an exact protected completed provision permits bounded mode
evolution: owner rwx, optional group/other read/execute, no group/other write or
special bits, and unchanged device/inode/UID/GID. The immutable staging proof
continues to record 0700; incomplete staging cannot select this path through a
supplied receipt. No chmod/chown or record repair occurs. These host filesystem
contracts do not qualify actual guest ownership/mode evolution or replacement
writes, and do not enable the volume descriptor or public admission.


The manually invoked volume-filesystem-proof example provides an ordinary Linux
host-filesystem witness. After an operator prepares the canonical private SDK
volume root and selects an existing empty enrolled domain, invoke prepare and
finish as separate processes with the same absolute DOMAIN_JSON and a fresh
absolute OUTPUT directory. It saves private original intent/provision/deletion
records and never initializes a domain, boots a VM or selects fault campaigns.
It checks protected proof reopening, both SDK mount tuple modes, mount-gate
exclusion, bounded tree deletion and outside link-target preservation. This is
not public-consumer or guest-volume qualification. Do not run it against macOS
export custody or reuse an incomplete output as a fresh preparation.

If fixture creation completed but a harness assertion failed, the explicit
verify-preparation phase checks the original protected provision and every known
fixture file/link before writing only the harness success marker. It cannot
replay provisioning, resume deletion or repair backing. Held mounts may reject
deletion at aggregate resource admission before the volume gate; the witness
records that exact pre-dispatch category and rechecks intact mount authority.


The separately invoked volume-guest-proof example is an ordinary Linux x86_64
mounted-container witness. Its first/second commands take a private SETTINGS_JSON
and the same private absolute OUTPUT (at most 88 bytes for its control socket).
Settings select canonical package/artifact/domain_json paths plus exact
manifest_sha256/artifact_sha256. The package inventory, helper and templates are
verified before opening the pre-existing enrolled domain. The canonical private
volume root must already be operator-prepared. No SDK source or CLI/server
fallback is used, and no default check invokes the live first/second commands.

The first phase provisions two original volumes, creates an offline mounted
container, checks commands/UTF-8 stdin/background launch/files/PTY, and stops
normally. The second phase reopens the exact original records under a new owner,
checks retained data/replacement writes, then performs original machine/volume
deletion. Read-only writes must fail, the numeric non-root user is exercised,
and guest backing chmod to 0755 must preserve original device/inode/UID/GID.
Completion markers require normal engine shutdown; they do not enable public
volumes or qualify other source/platform/store combinations.

On a failure, the process retains its original engine and private control socket.
Use control OUTPUT status, stop, delete-machine, delete-volumes, close-stopped
or close-cleaned for explicit ordinary teardown. No action signals a process or
adopts SDK inventory. close-unstarted is limited to this local-pack preparation
path before any attempted start; it normally closes the empty actor epoch while
preserving unknown preparation and every original intent/proof. It does not
resolve or delete unknown material. Failed controls/peer EOF preserve the owner.
The default runner selects only the example's deterministic socket/owner model
through cargo test --example volume-guest-proof, never its live main function.


The guest witness sets SMOLVM_LIB_DIR to the verified package library directory
for the parent SDK as well as retaining the approved worker loader context.
Its explicit cleanup SETTINGS_JSON OUTPUT command reopens only the original
returned machine receipt and protected volume proofs, requires an observed
stopped machine, and deletes them without starting a VM. It writes a separate
cleanup marker and never converts a failed qualification into success. Normal
stop also runs for an already stopped record to collect any original SDK handle.

For a preflight-capable approved package, the explicit ordinary lifecycle runner
accepts `--terminal-preflight`. It checks exact eligibility outcomes while the
owned image is stopped, running, retained across normal helper replacement, and
missing after owned deletion. Each observation checks unchanged SDK records, no
stream events and (on Linux) unchanged helper child inventory. It neither selects
crash fixtures nor signals an owner on failure. This option requires the separate
`terminal_preflight: 1` descriptor; the existing terminal flag alone is insufficient.


## Explicit ordinary OCI engine witness

`smolbox-engine/examples/oci-guest-proof.rs` is an opt-in Linux x86_64 witness for
anonymous digest-pinned OCI metadata, fresh direct creation, one-shot owned start,
commands, guest image listing/pull, normal stop/restart, retained data and owned
deletion. It uses the shared engine and public SDK APIs. Public OCI/image feature
admission stays disabled until the remaining P4 gates pass. Configured application
startup behavior, registry-artifact credentials and other source/resource/platform
combinations require separate acceptance.

Build explicitly with `cargo build --manifest-path native/Cargo.toml -p smolbox-engine
--example oci-guest-proof --release --locked`. Run the resulting
`oci-guest-proof run SETTINGS_JSON OUTPUT` against an already enrolled real
account/domain. The new private output directory must have a normalized absolute
path at most 88 bytes for its control socket. SETTINGS_JSON is a private bounded
JSON file containing `package`, `manifest_sha256`, `domain_json`, `source`,
`pull_source`, `network` and optional `startup_workload` (normally null).
For the fixed startup case, populate `startup_workload` from the executable's
`startup-fixture` subcommand. It prints the exact non-secret workload without
opening an engine. Other workload values are rejected before dispatch. The case
checks explicit argv/env/workdir, the image default user and startup-written
counters after first start and restart; it does not qualify inherited-command or
named-user variants.
The two sources have exact `reference` and `platform` fields, must be distinct
native-platform manifest pins, and are operator approvals. Network has explicit
`enabled`, sorted `hosts` and sorted `cidrs`; the witness adds no registry egress.
No local artifact, alternate database/root, per-request credentials or proxy is
accepted. Shared setup verifies the approved package/assets/templates and opens
only default SDK paths with initialization disabled.

Each stage and the returned original receipt stay in private evidence. A failure
retains the same engine/managers behind OUTPUT/control.sock. Inspect it with
`oci-guest-proof control OUTPUT status`; use explicit `stop`, then `delete`, then
`close-cleaned` for normal API cleanup. `close-unstarted` is allowed only before
any creation/start entry with an available empty engine. Failed or malformed
controls preserve the owner. There are no process signals, fault modes, retries
of lifecycle actions, or reconstruction of ownership from saved names/receipts.
The default native check runs only the example's pure approval models and the
shared normal owner-retention model; it never invokes this live CLI.

Host registry reachability is separate from the approved guest egress policy.
The first ordinary Linux attempt stops before creation because the existing
test/probe lab deliberately has no outbound route/DNS. Its owner closes normally
and the namespace stays empty; this is not successful OCI workflow acceptance.
Use an explicitly approved network-capable qualification environment for the
live path. The retained isolated lab and its default domain are not reset or
silently reconfigured for that purpose.


The approved separate-network Linux checkpoint
[293cd24/f6d11e57](../docs/evidence/embedded-port-http-parity-oci-linux-293cd24.json)
passes this ordinary shared-engine OCI/image witness, including restart/data
retention, owned deletion and normal shutdown with empty SDK tables. Docker
configuration metadata permits one credential-free HTTPS hop to the exact
`production.cloudfront.docker.com` blob endpoint, with digest/size/deadline checks;
manifest/token redirects and unrelated destinations remain rejected. This does
not qualify configured application startup or enable public OCI/image admission.


The later [14f45d6/25bed054 checkpoint](../docs/evidence/embedded-port-http-parity-oci-startup-linux-14f45d6.json)
passes the fixed configured-workload case on first start/restart, alongside the
ordinary image/owned-cleanup workflow. Its startup counter checks establish the
explicit argv/env/workdir and default image user case only. Registry artifact
blob downloads share the bounded Docker redirect transport; live registry-artifact
and credential acceptance remains pending. Current/minimum HTTP-only consumers
pass without Rust/assets; native public consumers on these bytes remain required.


For anonymous `.smolmachine` preparation, the same executable also accepts
`run-registry REGISTRY_SETTINGS_JSON OUTPUT`. Settings contain `package`,
`manifest_sha256`, `domain_json`, `source` (`reference`, `platform`,
`content_sha256`), `max_bytes` and `cache_policy` (`max_bytes`, `max_files`).
The witness requires an initially cold host cache and empty SDK inventory.
It verifies cold/warm preparation, fresh cached creation, normal exec/restart,
retained data, owned deletion and retained-cache requalification. Its original
owner and controls remain available on errors as in OCI mode.

`examples/proof_support/registry_fixture.py` is the explicit immutable loopback
registry fixture for that witness. Its required arguments are `--witness`,
`--package`, `--manifest-sha256`, `--domain-json`, `--artifact`,
`--artifact-sha256` and a fresh private `--output`. The approved artifact must be
canonical, owned, single-linked and read-only. The fixture starts no SDK service,
accepts no credentials and closes normally after witness collection. Requests,
receipts and raw evidence stay private. Default checks never invoke this CLI.
The fixture alone does not qualify credential rotation or public registry access.
`--preparations 1` selects the exact one-manifest/one-blob cold preparation used
by a single growth workflow; the default remains the two-manifest/one-blob
cold/warm image pair. All request counts remain exact. A one-preparation bearer
case can observe publication of the rotated account file, but cannot qualify a
later request using that token; only a successful two-preparation case sets the
rotation qualification flag.

The shared engine's operator-account registry path now reads the verified host
account's separate machines/images config, with SDK credential precedence and
mirror routing. It snapshots bounded files per operation, observes legacy image
entries without migration writes, and never serializes credentials into source or
result identity. Explicit operation credentials override account credentials.
Account identity tokens use an exact `[smolbox.registry_token_realms]` entry keyed
by registry when an external exchange realm is needed; without it only HTTPS on
the registry origin or Docker's documented auth host is accepted. Basic exchanges
follow SDK host rules and require HTTPS. Model checks cover these boundaries;
additional authenticated acceptance and changed-package consumers remain pending.
Docker providers now use bounded nonblocking output, reserved direct-child/pipe
resources and exact collection. Descendant pipe ambiguity retains the owned job
and fences work, without promoting late credentials or signaling an unowned
descendant. Providers are trusted operator programs. Pure models cover retirement
and malformed/oversized output; ordinary local fixtures cover success, missing
entries and large valid replies, without termination campaigns.
Public registry/image admission is
still disabled, and earlier package evidence does not qualify changed engine bytes.

The explicit registry fixture also accepts `--mode account-bearer` for an ordinary
fresh-account witness. It creates a private operator config at the real account's
default path, routes a fixed registry name through its loopback mirror and rotates
the bearer between cold and warm reads. It rejects wrong/duplicate credentials
and records counts rather than raw headers. This changes only operator config,
never SDK persistence. It now passes scoped Linux qualification on package
36ed1c49; it does not qualify TLS exchanges or other credential modes.

Guest OCI pull/start now resolves the images account view in the admitted owner
and transfers credentials/routing only in the private worker input pipe. The
worker never reads host settings; registry tokens do not enter metadata spools,
startup hashes, receipts, argv or environment. Guest pairs and Docker identity
tokens follow SDK guest rules, separately from host identity exchange. The input
ceiling is 256 KiB for pull/bootstrap frames carrying parent-selected registry
setup; inputs without it and worker output stay at 16 KiB. Legacy anonymous
frames remain compatible.
Normal macOS worker/peer checks cover nine pull and eight bootstrap cases,
including large valid credentials. They start no VM and confer no new package
qualification. Mirror replies still need the original approved reference; alias
rewrites are rejected consistently with the strict HTTP source identity contract.
Real guest registry/mirror, other platform and public consumer gates remain pending.

The changed Linux package 36ed1c49/helper 7c81a6bf passes ordinary host registry
bearer/mirror/rotation and anonymous OCI/image/configured-startup acceptance on
unmodified SDK 9f446ae. Both cases verify owned deletion, empty SDK tables and
normal owner collection. The private archive verifies locally/outer before normal
provisioning shutdown with the original run disk unchanged. Its 806 assets match
64a20a93. [Scoped evidence](../docs/evidence/embedded-port-http-parity-registry-oci-linux-5788a29.json)
does not qualify guest credentials, all exchanges or public P4 admission. Other
source/resource/platform cases and public P4 consumers stay required.
The same package now passes [current/minimum public offline and terminal consumers](../docs/evidence/embedded-port-http-parity-linux-public-consumers-5788a29.json)
without Rust, including binary files, draining, graceful stopped Runtime replacement,
retained data and owned deletion. SDK/process/zombie inventories are empty and
the account lock is free before normal provisioning shutdown. Current/minimum
HTTP-only consumers also pass without Rust/native assets. Public image/registry
admission remains disabled.

The subsequent Linux source candidate adds `remote_sources: 1` and `images: 1`
to its exact package policy and public SDK admission, with the separate
`hello-v2-linux-images.json` fixture. Default/macOS and older descriptors stay
unchanged. Rebuilding changes the helper/manifest identity and requires fresh
operator approval and its own ordinary public qualification; 36ed1c49 above does
not acquire the new features. The explicit public image consumer is selected
through `--native-public --native-images` with private bounded source settings.
It retains the original owner on failure.

Source 30239b6 rebuilds exact Linux manifest e7387c9c with 1,121 native checks,
strict all-target Clippy and unmodified SDK inventories. Its first current/minimum
public OCI attempts fail at pull and retain their owners/disks. Assigned-context,
managed-key and accepted-retry fixes now pass deterministic Elixir checks;
explicit cleanup and corrected public reruns remain required. See the
[scoped rebuild evidence](../docs/evidence/embedded-port-http-parity-public-images-linux-e7387c9c.json).
No historical acceptance transfers to this package.


The [d6482f3/25bed054 registry checkpoint](../docs/evidence/embedded-port-http-parity-registry-linux-d6482f3.json)
passes the fixed anonymous bare workflow, including cold/warm preparation, fresh
cached creation, normal exec/restart/data, owned deletion and retained pack-cache
requalification. Bare execution omits the image-only user option. The fixture
observes two manifest GETs and one blob GET and closes normally. Credentials,
other source/platform cases and public source admission remain unqualified.

## Explicit ordinary branch engine witness

`smolbox-engine/examples/branch-guest-proof.rs` prepares the ordinary Linux x86_64
local-bare branch campaign. Its live path has not yet been qualified. It uses the
shared engine with a verified package's boot/file helpers; it is a maintainer
witness, not a public Port consumer or a capability activation.

Build the witness and helper from the same frozen, verified unmodified-SDK source:

```sh
cargo build --manifest-path native/Cargo.toml -p smolbox-engine --example branch-guest-proof --release --locked
```

Live entries require an explicit mode:
`branch-guest-proof ordinary SETTINGS_JSON OUTPUT` or
`branch-guest-proof ordinary-partial-cancellation SETTINGS_JSON OUTPUT`.
The latter is an opt-in shared-engine cancellation witness. It prepares the source,
calls the original retained boot API to completion, then cancels that operation's
token. It verifies that initialization rejects before dispatch and no completed
branch exists, then uses the original retained collection, disposal, absence and
backing controls. It injects no process loss or launch pause. This is engine-only
evidence; it cannot qualify public Port or durable Runtime coordination. Neither
mode is invoked by default tests, and neither selects deferred fault validation.
Use an enrolled dedicated account/domain with an initially empty SDK inventory.
The output must be a new private normalized absolute directory, at most 88 bytes
for its control socket. The bounded private settings file contains:

```json
{
  "package": "/approved/package",
  "manifest_sha256": "<exact package.json SHA-256>",
  "domain_json": "/approved/domain.json",
  "artifact": {
    "path": "/approved/bare.smolmachine",
    "sha256": "<exact artifact SHA-256>",
    "max_bytes": 2147483648,
    "guest_platform": "linux/amd64"
  },
  "branch_approval": {
    "id": "ordinary-branches",
    "host_overhead_mb": 128,
    "resources": {"slots": 1, "cpus": 1, "memory_mb": 640, "disk_gb": 5}
  }
}
```

The source is fixed at one CPU, 512 MiB RAM and 1-GiB storage/overlay disks, with
checkpointable startup and offline networking. The existing engine validates the
bare artifact and rejects incompatible sources. The guest must provide the public
SDK's `smolvm-branch-ready` helper. This runner supplies no registry, networking,
host mount, checkpoint-source import or arbitrary workload settings.

The live sequence prepares disk and RAM markers, parks the source's branch-ready
helper, creates an initially released child and a held sibling, verifies held and
source lifecycle restrictions, explicitly releases the held child, and checks
independent source/child RAM and disk changes. Normal first-child stop/start must
preserve disk and discard its captured RAM. Deleting that child must leave the
source blocked by the remaining sibling and leave that sibling usable. Both child
absence proofs, source deletion and separate backing acknowledgements precede
normal owner shutdown. Output records both the package manifest and the witness
executable digests; they identify a pair, not interchangeable qualifications.

Original branch-manager collection uses the same public SDK disk resolver as
boot: fork children can have `storage.qcow2` / `overlay.qcow2` rather than raw
files. Collection requires the original manager's exact resolved paths, protected
directory identities and owned regular files without symlink redirection. It
does not freeze a running guest's disk contents or construct a manager from files.
Runtime ownership exclusion uses the same engine's shared runtime-boot registry,
including pending starts. The SDK's PID accessor also reads database rows, so a
PID row cannot distinguish the original manager from an ordinary runtime owner.
Context installation/selection binds the original registry pointer; manager maps,
enrollment, PID/birth and epoch checks remain mandatory before collection.
At verified handoff the original context also retains its actual manager's
selected raw/QCOW locators, bound to the original child-directory identity.
Historical collection/continuation checks compare those immutable locators even
after a namespace was removed. They never reconstruct a manager or attest
collection. Live collection still checks current directories/disks; mutating
continuation still requires positive original collection, the current protected
plan and exact row. No file inventory can replace this original context.
The witness records successful first-child stop and restart separately, so a
later failure cannot qualify the remaining lifecycle sequence.

On failure, returned facts remain in the original in-memory owner before any
fallible evidence write. `branch-guest-proof control OUTPUT status` reports only
the original tracked states. Explicit `stop-source`, `stop-first`, `stop-held`,
`delete-source`, `delete-first`, `delete-held` and `release-held` invoke only their
normal original APIs. An entered uncertain lifecycle cannot replay. After proved
child deletion, `qualify-first-absence` / `qualify-held-absence` collect typed
absence evidence; after source deletion, `release-first-backing` /
`release-held-backing` use the exact retained requests. `close-cleaned` requires
all entered members deleted, all entered children's absence/backing acknowledgements,
an available engine and empty inventory. A child never entered by this owner needs
no invented deletion. `close-unstarted` requires no source creation entry.
`close-retained` requests normal engine shutdown while preserving uncertain
records and disks. It grants no deletion, absence, retirement or backing proof.
If normal shutdown fails, the witness retains its original owner and controls;
there is no forced termination fallback.

Partial creations without returned original completion retain their requests and
engine authority. Their explicit controls now use that same retained engine:

| Controls (replace `CHILD` with `first` or `held`) | Original authority required |
| --- | --- |
| `inspect-retained-CHILD`, `qualify-ready-CHILD` | Original retained phase, or protected completion plus fresh running source/child observations. Phase names alone grant nothing. |
| `publish-collected-CHILD` | Exact original verified worker output and frozen creation, source/child gates and protected publication. Uses one fresh control deadline; no fork or boot is repeated, and the child remains unknown. |
| `retire-prepared-CHILD` | Positive original unused declaration; empty inventory cannot supply it. No child deletion or backing proof is invented. |
| `dispose-unbooted-CHILD`, `resolve-unbooted-CHILD` | Original published/unbooted context. The second control observes the exact accepted request and never repeats SDK entry. |
| `collect-partial-CHILD`, `dispose-partial-CHILD`, `resolve-partial-CHILD` | Original opaque pre-handoff enrollment and typed collection, followed by one disposal entry or separate observation. |
| `cleanup-partial-CHILD`, `qualify-cleanup-CHILD`, `resolve-cleanup-CHILD` | One explicit residual cleanup request, then distinct actual-removal or unnecessary-cleanup lookups. Neither lookup falls through to mutation or to the other lookup. |
| `finish-disposal-CHILD` | Protected original disposal proof and terminal archival; dependency/backing lifetimes remain separate. |
| `qualify-held-release` | Exact original held completion and saved release request, followed by fresh running observations. It never repeats activation. |

A collected publication can be explicitly completed before selecting unbooted
disposal. The control preserves the returned proof and receipts before evidence
IO, and never creates a ready completion. Pending raw/owned child rows, marker and
material-journal writes continue only under the original protected publication.
Already completed publication is historical lookup, including an inactive later
boot, identity or release phase under the same retained original owner. It reads
only the synchronized original proof without regressing phase or repeating the
publisher; missing history or active work rejects. A new control cannot extend
the captured deadline of an existing control. The full original creation keeps
the initial activation choice, which a publication alone cannot attest.

The native protocol-two side also accepts `publish_collected_branch_material`
with that full original creation and `quiesced: true`. It requires the exact
branch approval and Create capability, uses the existing control lane and caps
the entire request at 30 seconds with a 16-KiB creation. Its distinct
`collected_branch_material_published` result contains only the bounded material
publication, correlated with the source, child, approval, platform and original
epoch, with no stream output. The shared engine selects its original retained
context; serialized requests cannot create one. Existing branch output limits
leave room for both observers under a stalled writer. Elixir validates the same
request/reply, quiescence, bounds, source/child/approval and original epoch/platform
correlation, with zero stream output. Its current package still refuses dispatch
before native IO even with the operator catalog. Backend/Runtime/store public
continuation, installed consumers and ordinary package recovery remain required;
these framing boundaries do not enable public branch admission.

The existing absence/backing controls select completed, unbooted or collected
partial proofs according to the original result. Accepted cleanup must have its
own typed acknowledgement before backing closure. Phase routing rejects the
wrong kind before accepting a new request; the engine still independently checks
all actual authority. Source cleanup waits for entered children to be proved
absent or positively retired as unentered, preserving their original context.
`status` labels retained phase observations as historical, not current authority.

Missing enrollment, active work, substituted roots or missing original context
remain uncertain. These controls do not reconstruct an SDK manager from inventory,
and a failed witness must not be terminated as an automatic cleanup step. There
are no process-signal, crash, pause, forced-exit or arbitrary-command controls.
Default checks select only pure Rust models, never the live entry point. See the
[control evidence](../docs/evidence/embedded-port-http-parity-branch-witness-controls.json)
for the scoped checks; it supplies no live SDK outcome.

This witness does not exercise durable paired dependency retirement, framed Port
branch routing or public current/minimum no-Rust consumers. Those campaigns and
other required platforms/sources remain P8/P9 acceptance gates. Public native
branch admission stays disabled; distribution approval stays separate.

The [preparation evidence](../docs/evidence/embedded-port-http-parity-branch-witness-preparation.json)
records only pure models, source/tooling checks and documentation validation.
It supplies no live branch result.
