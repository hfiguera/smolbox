# SmolBox native workspace

The embedded Port backend supports explicitly approved development packages.
The workspace builds against an unmodified SDK. Exact engine 0.1.0 packages have
completed ordinary development qualification on Linux x86_64 and macOS arm64;
an exact rebuilt Linux 0.2.0/protocol-2 package now has
[ordinary raw Port lifecycle evidence](../docs/evidence/embedded-port-http-parity-linux-lifecycle.json).
Public consumers, stores and expanded feature qualification remain pending. Follow the
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

The protocol crate builds independently of hypervisor assets and implements
bounded framing, [versioned DTOs and admission/credit state](smolbox-protocol/README.md).
Protocol-2 packages declaring `streaming_exec: 1` expose the owned streaming
command worker through compact input and byte/event-credit output. Public nil-stdin
command bounds and actual Exit evidence are preserved; stores must advertise
`native_streaming_commands: 1` after upgrading all native v17 readers. The
transport-independent engine remains reusable by a future Rustler bridge.
Ordinary new-package guest/platform qualification remains pending.

Protocol-2 packages declaring `terminals: 1` route managed retained-image terminal
sessions through the shared engine and an owned `run_interactive_io` worker.
Protected private IPC authenticates the parent, metadata and operation identity.
Machine/source/domain leases and shared resource reservations remain held through
exact child collection. Unknown collection retains leases and quarantines
admission; EOF, local close or cancellation cannot substitute for guest Exit.

The Port adapter forwards initialized/output/input/resize/close events with finite
budgets and bounded queues. Worker initialization does not prove guest readiness.
Only whole consumer removal restores output credit. Neither the bridge nor the
store persists a transcript, connection or input for replay. SDK I/O uses the
bounded existing-agent relay, without a host tty or signal handler.

Stores must advertise `native_terminal_sessions: 1` after all native v17 readers
and command-slot transactions are upgraded, alongside ordinary terminal markers.
Current/minimum consumers and ordinary Linux/macOS PTY qualification for the new
package bytes remain pending. Public Runtime peers and non-VM SDK/child checks
are scoped evidence; they do not transfer historical platform qualification.

`smolbox-engine` consumes the exact source pin and implements
prepared creation, intent-bound absence checks, receipt-checked observation/lifecycle, and bounded foreground
exec normalization, and capped guest file transfers. Earlier 0.1.0 packages
have macOS proof evidence. The [framed helper](smolbox-port/README.md), internal Elixir Port owner and
record-scoped adapter have also run macOS proofs, including encrypted PostgreSQL
recovery across fresh BEAM processes. Pack structure and geometry are validated
before reservation. Public development admission is available; distribution and full crash
qualification remain separate gates.
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
finite startup budget. This option never selects deferred crash campaigns.

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

The script also builds the helper and explicitly selects the two `ordinary_worker`
fixtures and one `ordinary_boot_guard` fixture. The guard fixture uses invalid SDK
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
on old SDK hooks and do not qualify the SmolBox-owned guard. Crash validation is
deferred; future fault qualification requires fixtures for the clean architecture.

For normal VM validation without deliberate interruption, use
`smolbox-port/tests/ordinary_proof.py` with `--package`, `--fixture`, `--sha256`,
`--domain-json` and a new `--output` directory. It checks actual execution/resources,
numeric non-root UID, binary file transfer, retained stop/start, normal shutdown
of a helper whose VM is already stopped, fresh-helper reopening and full-receipt
deletion. It preserves the initial inventory and records the exact package tuple.
Its report explicitly leaves crash handling unqualified. This is a separate
validation scope; it does not replace or weaken the fault-proof expectations.

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
qualification remain part of the unfinished migration; crash validation is deferred.
