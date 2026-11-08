# Embedded Port implementation progress

The [design](embedded-port.md) and [full implementation plan](embedded-port-implementation-plan.md)
remain the acceptance authority. This file records implementation evidence and
outstanding gates; a milestone does not qualify the embedded backend for use.

## Backend extraction milestone — October 10, 2026

Managed orchestration now uses `SmolBox.Backend` operation references and budgets.
`Backend.HTTP` delegates to the existing public Client and transport extension.
HTTP-specific health classification, terminal opening, and branch operations sit
inside that adapter. Existing `WorkerConfig` declarations normalize into internal
targets with stable logical IDs; public HTTP declarations remain supported.

Lifecycle, file staging/collection, recovery/cleanup, optional managed operations,
worker inspection/control/reporting, and telemetry use this boundary. Budget
clamping cannot increase a target's operation limits. Unsupported operations fail
before adapter invocation. References and normalized targets redact host context.
No native target is admitted yet, and no persistent record encoding has changed.

Validation on macOS Apple Silicon, Elixir 1.20.4 / OTP 29.0.6:

- Baseline deterministic suite: 636 passed, 29 native/runtime cases excluded.
- Extraction plus five new capability/budget/evidence/redaction checks: 641 passed,
  with the same 29 exclusions. Existing HTTP peer contract tests are included;
  they are not live hypervisor qualification.
- `mix ci` passed after correcting an alias-style finding in the first run:
  formatting, dependency use, compilation, cycle checks, tests, strict Credo,
  clone checks, Credence, and Dialyzer with no errors.

Remaining Phase 1 gates include backend-specific native observations and live HTTP
regression qualification. All native functionality, store migration, native fault
campaigns, package-consumer checks, and release documentation remain outstanding.

## Native source and integration gap record

Pin smolvm 1.22.0 to `9f446ae00219148ca4a703914f44a8e2fab11655` from
`https://github.com/smol-machines/smolvm`. The research checkout is not modified or
used as a Cargo path dependency. The native workspace consumes this exact source
pin in `smolbox-engine` and `smolvm-pack` through a verified offline source
snapshot and separately recorded public-API patch. `native/vendor/source.json`
records archive/patch digests; `native/Cargo.lock` locks the resolved dependency
graph. `native/bootstrap.py --check` verifies the complete patched source cache.

The research bundle's provenance lists libkrun
`3285db7404144ed61faf0848bb424c0f82743f41` and libkrunfw
`bfb229911374698399dcedcc92019287870759ab`. These identify research inputs, not a
qualified SmolBox native package. The source library is Apache-2.0. Distribution
must audit actual bundled libkrunfw/kernel licenses and corresponding source;
the upstream prose's version labels alone do not establish binary provenance.

| Gap | Evidence and required integration |
| --- | --- |
| Prepared image creation | `MachineSpec::to_record` does not verify/materialize a pack or store its provenance. Reuse public pinned sidecar verification and `materialize_pack_layers`, preserve neutral startup, and integrate complete registration. Verify disk topology and handle VM-mode packs explicitly before claiming acceptance. |
| Observational state | Read `SmolvmDb::get_vm` with explicit error handling and verified process/agent evidence. Convenience stopped/false methods and state-probe paths with hidden DB errors cannot authorize cleanup. |
| Native domain | Default DB and cache lookups recur below `with_db`. Initial implementation must enforce one default-path domain per account with a domain-generation binding and OS lock, unless a complete path-context patch is implemented and qualified. |
| Cancellation | `exec_streaming_with_options` can return `Ok` without Exit after cancellation; Error events can accompany `Ok`. Completion normalization must preserve actual Exit/Error/cancel evidence. |
| Bounded files | Default native read collects potentially gigabytes. Use capped agent transfer APIs, owned staging, per-operation deadlines, and bounded framing. |
| File cancellation API | The separately recorded connection patch exposes socket cloning and a caller-selected timed constructor. The engine now uses an independent socket abort deadline alongside capped transfers. The upstream reader's 600-second read timeout cannot defeat that abort. |
| Mutation interference | Engine per-machine gates serialize its own callers, but upstream lifecycle helpers reread records and do not accept an expected receipt inside their mutation locks. Qualify interference with an independently operated CLI and resolve expected-record fencing before declaring lifecycle safety complete. |
| Lifetime | Parent watching, record persistence, and handle destruction differ. Explicit owner-bound shutdown must stop only owned VMMs, retain disks, and reap only owned children. |
| Boot helper | `_boot-vm` is a public library entry point. Image seed preparation instead requires CLI subcommands; disable seeds for the minimal helper and prevent boot debug logs reaching protocol stdout. |
| Packaging | A preexisting macOS 1.22.0 bundle is available for research. Build/sign the actual helper with matching libraries/rootfs/templates, verify assets, and run a fresh native proof before declaring Phase 0 passed. |

Phase 0's real create/boot/exec/file/stop/delete proof has now run on macOS arm64
with the recorded connection patch. Other native API/package gaps and full
qualification remain active work; this is not a completed Port release.

## Framing milestone — October 10, 2026

`native/smolbox-protocol` implements four-byte big-endian framing, a 1 MiB encoded
frame maximum, clean EOF versus truncated-frame distinction, bounded JSON depth,
collections/scalars, redacted parse failures, and capped outbound serialization.
It is independent of hypervisor libraries and Rustler. Versioned message DTOs,
request correlation, credit, deadlines, and helper integration are still pending.

`cargo test --manifest-path native/Cargo.toml --locked` passed five framing tests;
`cargo clippy --manifest-path native/Cargo.toml --all-targets --locked -- -D warnings`
passed. Tests cover fragmented/concatenated frames, rejected excessive lengths
before body reads, partial headers/bodies, malformed JSON and limits, and outbound
overflow without partial frames. These checks do not qualify the full protocol
or a native VM lifecycle.

## Shared native engine milestone — October 10, 2026

`native/smolbox-engine` now consumes smolvm and smolvm-pack 1.22.0 at the exact
recorded revision. Its public domain operations use typed Rust values independent
of JSON framing, Erlang terms and Rustler. Private native-record hashing uses the
pinned serialized schema; only lifecycle state, PID/start time, last exit and
init-completion fields are excluded from the material fingerprint.

Implemented native paths, awaiting live qualification:

- Prepared creation copies and hashes the approved local pack into a private
  content-addressed cache, verifies its pinned footer/checksum, reads a bounded
  manifest, checks architecture and supported topology, reserves the name, and
  uses upstream public pack materialization and VM-mode disk seeding APIs.
  It commits a complete neutral `/bin/true` record. Baked workloads, secrets,
  GPU/CUDA and workspace seeds are not silently enabled. VM-mode logical sizes
  must match admitted disk sizes; vCPU requests above the native limit fail.
- Creation returns a domain-bound receipt containing material identity and a
  fresh caller-selected incarnation, also stored in a private per-VM marker.
  Inspection/lifecycle require that receipt; labels alone do not authorize them.
  Partial preparation errors remain potentially dispatched and retain storage.
- Observational inspection distinguishes typed DB failure, verified absence,
  partial-storage uncertainty, stopped, failed, paused/pausing/frozen, unverified
  live PID, and agent-unreachable state. It never starts or materializes a VM.
  Reported resources are stored configuration, not proof of guest application.
- Foreground execution uses dedicated upstream connections, argv/env/workdir and
  image-qualified user options, decoded-byte caps, ordered 64 KiB output chunks,
  explicit consumer failure, and an independent host deadline/cancel token.
  Rust success without Exit stays unknown; Error plus Exit cannot become success.
  Cancellation does not assert guest termination.
- Per-machine gates keep lifecycle and exec requests from overlapping while
  allowing other names to proceed. Graceful shutdown attempts to stop only
  explicitly tracked owned handles and invokes scoped native child reaping;
  it never sweeps shared inventory or deletes disks on helper exit.
- Account/domain OS locks prevent duplicate engine authorities, including helpers
  with differing default-path environments. Persisted target/generation/path
  bindings cannot be overwritten at initialization. Boot seeds/debug/path-root
  environment guards prevent accidental CLI seed work or stdout contamination.

Validation: macOS arm64, rustc 1.99.0 / Cargo 1.99.0, using private copies of the
research libraries for the upstream build script. Locked workspace tests passed
15 engine and 5 framing checks; Clippy across all targets passed with warnings
denied. Engine tests include corrupt SQLite JSON, copied labels with changed
material fields, missing incarnation markers, non-materializing absence,
partial-storage uncertainty, per-machine contention, PID/start identity, stream
evidence, output limits and independent cancellation. No VM was launched by
these tests. Formatting checks passed for both workspace packages.

At that milestone, the native create/boot/exec/file/stop/delete proof and bounded
file APIs, exact package preflight, mutation interference, helper DTOs/queues,
Elixir Port supervision, store codecs/recovery, live HTTP/native qualification,
consumer packages and release guides remained required. That milestone did not
declare any public embedded capability available or complete Phase 0 or Phase 2.

## Capped files and macOS native proof — October 10, 2026

The engine now implements atomic agent file writes from bounded input and capped
reads to an owned temporary file, forwarding 64 KiB chunks after complete native
download. It enforces a 16 MiB file maximum, finite host deadlines and safe
path/mode validation. Per-operation cloned sockets support cancel before/after
attachment; cancellation does not wait for a VM lifecycle gate. RAII detaches
those sockets on completion or unwinding. File outcomes preserve native
acknowledgment separately from consumer completion or cancellation.

The source snapshot pins the existing revision/tree, includes upstream licenses,
and applies only `0001-agent-connection-cancellation.patch`. Integrity tests cover
archive/patch changes, edited caches, traversal, and destination symlinks. The
build wrapper uses copied libraries because the SDK build script rewrites them.
Rust 1.99 emits two deprecation warnings in the pinned upstream path dependencies;
SmolBox's test, Clippy and Rustdoc commands pass. The patch does not rewrite those
upstream APIs just to hide toolchain warnings.

Actual macOS arm64 native proof used the newly built `owned-proof` executable,
ad-hoc signed with the hypervisor entitlement, and private copies of the smolvm
1.22.0 macOS runtime assets. It generated an approved offline Alpine image whose
baked entrypoint exits 97; engine startup instead used neutral `/bin/true`.
The first attempt omitted libepoxy and failed safely at boot; the exact receipt
was cleaned up explicitly, then the complete library set was used for a fresh
creation intent. Do not claim package preflight from this successful rerun.

Verified final behavior:

- Real foreground Exit 0, separate stdout/stderr, environment and `/workspace`
  workdir; configured root user and a qualified numeric non-root user 65534.
- Guest witness: one vCPU, 495648 KiB usable memory for the 512 MiB request, and
  2097152 sectors each for storage/overlay (1 GiB each).
- A finite sleeping command reached its host deadline without an observed Exit
  or fabricated success; subsequent file operations continued on the target.
- 1048593 bytes were atomically uploaded, acknowledged, collected exactly,
  preserved through stop/start, and collected again.
- Verified stopped state before deletion, verified machine absence after
  deletion, empty owned handles, and native DB inventory unchanged at zero.

The final proof saves intent before create and refuses reuse of either intent or
receipt output; uncertain creation cannot be replayed. Evidence artifacts retain
exact executable/library/rootfs/template/source/fixture identities under
`.local/embedded-native-proof/`. The proof uses the shared engine's APIs and its
own `_boot-vm` entry point; it does not start HTTP or spawn CLI domain operations.

Validation passed 19 engine tests, 5 framing tests and 4 source-integrity tests,
formatting, Clippy across targets, and Rust documentation with warnings denied.
This is one ordinary macOS native proof, not Linux qualification, a fault
campaign, a distributable signed package, durable BEAM recovery, or a Port
protocol/bridge qualification. Those required gates remain open.

## Protocol DTO and admission milestone — October 10, 2026

This milestone established the initial 1.0 development contract with typed
Hello/approval, requests, acceptance, events, terminal outcomes, cancel, credit,
upload and shutdown messages. It rejects unknown fields/variants and validates
receipt/domain identity, finite durations, scalar/resource/path constraints and
canonical capped base64. Frame decoding now rejects duplicate JSON keys at every
depth. DTOs avoid Debug so diagnostics cannot print commands, tokens or files.

Helper-side Session state requires exact ready-handshake approval. Strictly
increasing IDs bound duplicate detection without retaining completed history.
Admission holds at most 32 operations and rejects absent capability, wrong domain
and overload before scheduling. Acceptance contains no running/dispatch evidence.
Per-request sequences, output stream/byte limits, credit acknowledgment, ordered
upload offsets and exactly one terminal are enforced. Late cancel/credit races
are harmless; future IDs and wrong epochs fail. Control never needs free admission
capacity. A 65536-event limit leaves room for terminal completion. The declared
aggregate queues are 8 MiB decoded and 12 MiB encoded; actual queue implementations
and slow-reader qualification remain required.

Terminal validation preserves observed Exit independently of completion and
native acknowledgment independently of file forwarding. Successful stream
completion must account for every forwarded byte. The engine now retains a real
Exit that follows Error, output-cap failure or consumer failure, while keeping
that failure's disqualification of success. Checked-in request/terminal fixtures
use invented identities, not proof receipts.

Validation passed 20 engine tests, 6 framing tests, 12 protocol contract tests and
4 source-integrity tests. Contract tests include full admission with independent
control, stale IDs/epochs, cross-domain receipts, exact handshake approval,
noncanonical base64, ordered/capped uploads, credit and event exhaustion, omitted
Exit/ack evidence and truncated-success rejection. Formatting, Clippy and Rustdoc
passed; the pinned upstream deprecation warnings remain as previously recorded.
No VM was launched for this milestone and HTTP Elixir code was unchanged.

This supplies protocol state and fixtures, not a self-booting framed helper.
Worker/control queues, output writer, upload spools, package preflight, bounded
shutdown/EOF and the BEAM decoder/broker remain open. In particular, Session does
not enforce OS I/O queue limits or launch/cancel native work; those integration
and fault gates must pass before any public capability is declared available.

## Executable helper and framed native proof — October 10, 2026

`native/smolbox-port` now runs the shared engine through versioned framed stdio,
with `_boot-vm` dispatched by that same executable. The reader performs exact
approval, bounded request admission, cancel and credit independently of native
workers and upload disk I/O. Four work threads, two cancel threads and 32 accepted
operations are bounded separately. Scheduling acknowledgment never asserts native
dispatch or running observation. Catalog mismatch and overload reject before
native dispatch. A regression test covers cancel before the coordinator has even
processed an accepted request; another covers a queue-timeout/worker-start race
so a started call cannot be retired as not dispatched.

Upload spools have a 128 MiB aggregate declared-size bound and 16 MiB per-file
limit. Guest write starts only after every ordered chunk is present, using the
engine's new streamed reader API. Output has one writer, 8 MiB decoded/12 MiB
encoded bounds, 4096 event slots and 65 reserved control slots, with in-progress
writes still charged. Workers release the registry lock while waiting at most
one second (or remaining budget) for credit. The helper separately bounds writer
stalls, cancellation grace, shutdown and stuck coordinator/registry time. EOF
stops only tracked owned VMMs and retains storage. A lost channel/panic never
fabricates an Exit or a replacement terminal.

Package preflight checks caller-pinned manifest identity, compiled source,
executable hash, complete required assets, file/link hashes/sizes/modes, installed
host tool and the actual macOS signature/hypervisor boolean entitlement. The
helper has an executable-relative library search path; the proof clears DYLD and
runtime overrides. The separately recorded template selector patch is necessary:
unpatched smolvm prefers home templates over executable assets. A configured
absolute `SMOLVM_TEMPLATE_DIR` now selects only verified package templates,
without fallback. Tests prove that an existing executable-directory fallback is
ignored. This patch does not provide per-target DB isolation or mutation fencing.

The local package builder clones caller-provided templates, shrinks only those
owned clones to 1 GiB, copies libraries/rootfs, ad-hoc signs macOS, and records
exact source/build/asset identities. It does not download or publish. Local
packages currently pin a host resize2fs path/digest; portable package consumption,
distribution signing, binary licenses/corresponding source and release automation
remain open. The source archive remains unchanged; ordered patch checksums and
source metadata now include `0002-explicit-template-assets.patch`.

The first debug-package run exceeded its startup hash-verification timeout,
without sending a VM request. Its startup-child cleanup was corrected; inventory
stayed empty. Optimized verification exposed a literal dotted-plist-key issue,
which was fixed and verified with the local signing utilities. Fresh intents were
used for subsequent proofs, rather than replaying the first intent.

The final optimized, signed macOS arm64 helper passed the actual framed sequence:

- Exact package/domain/protocol/capability/limit approval; every response/event
  matched epoch, request ID and sequence.
- Prepared create returns a durable receipt; neutral start replaces the approved
  image's baked Exit 97 entrypoint. Real command stdout/stderr and Exit 0 are
  preserved, including environment/workdir and qualified numeric user 65534.
- Guest witness: one vCPU, 495648 KiB memory for the 512 MiB request, and 2097152
  sectors each for the 1 GiB storage and overlay.
- Atomic 1048593-byte upload and exact collection exceed the initial credit window
  using replenishment; no whole-file helper buffer is used.
- Idle helper stdin EOF exits successfully, stops its VMM and retains record/data.
  A fresh helper epoch observes the same receipt stopped; explicit start and
  collection recover the exact file, without recreating the machine.
- A finite sleeping command reaches its deadline without an observed Exit; explicit
  verified stop resolves VM termination before owned delete and missing observation.
- Both helper stderr files are empty; no helper/VMM processes remain and native DB
  inventory returns to zero. The initial inventory was empty, so this is not a
  claim of live foreign-CLI interference qualification.

Final proof evidence/intent/receipt live under
`.local/embedded-port-proof/qualification-final/`; package identity and every asset
are pinned under `.local/embedded-port-proof/release-package-final/package.json`.
An actual missing-libepoxy check emits only a framed rejected Hello plus the safe
stderr category, exits before opening the engine, and leaves inventory unchanged;
the owned package asset was restored to its verified hash afterward.

Validation passed 20 engine, 6 framing, 12 protocol and 13 helper checks, plus the
4 source-integrity tests, workspace formatting, Clippy and Rustdoc. The helper
checks use injected native fixtures and launch no VM; live claims above come from
the separate actual native proof. Existing upstream deprecation warnings remain
recorded, with no cosmetic patch to hide them. No Elixir HTTP code changed.

This completes a meaningful native helper milestone, not the full Port release.
BEAM supervision/configuration/result translation, selective durable codecs and
recovery, upstream expected-record mutation fencing, Linux, the full fault
campaign, fresh package consumers and release guides/automation remain required.
The public embedded backend remains unavailable until those gates are satisfied.

## Elixir configuration and bridge contract — October 10, 2026

`SmolBox.Embedded.Config` now validates a stable target ID and explicit domain
generation, an exact approved native package identity and manifest digest,
bounded prepared-artifact approvals, offline profiles, capacity declarations and
allocation floors. Construction performs no file access, domain enrollment,
helper launch or hypervisor probe. Existing-domain use is the default; initial
enrollment requires an explicit flag with the operator-supplied generation. No
arbitrary DB/path-context override or detached lifetime is accepted. Rustler
selection returns unsupported before dispatch until an implementation exists.

`SmolBox.Embedded.Limits` supplies finite broker budgets bounded by the protocol.
Initial credit across all allowed in-flight requests must fit the event queue.
The package/domain/artifact approvals are redacted from struct inspection.

`SmolBox.Embedded.Bridge` specifies asynchronous submission and correlated
acceptance, decoded output, terminal and channel-loss events. The observer
acknowledges bytes after consumption; caller monitoring and independent
cancellation/draining belong to the supervised bridge owner. Handles, helper
epochs and bridge choice never become durable assignment identity. Channel loss
must preserve uncertainty rather than inventing native completion evidence.

Seven focused tests cover side-effect-free construction, identity mismatch,
unsupported domain/bridge options, malformed structs, artifact ambiguity,
profile/floor rejection, redaction and aggregate credit bounds. This is a
configuration/contract component; the Port broker, runtime integration and
durable native recovery remain required before public embedded admission.

Validation passed all 648 deterministic Elixir checks (29 live-runtime checks
excluded). After splitting the configuration validator to satisfy Credo's
complexity limit, its 7 tests plus the 5 backend checks passed again. Formatting,
warning-free compilation, zero xref cycles, strict Credo, ExDNA, Credence,
test-environment Dialyzer (zero errors) and ExDoc generation passed. No HTTP
behavior or application startup path changed.

## Bounded message credit and BEAM channel state — October 10, 2026

The unreleased protocol is now **1.1**. Byte credit alone allowed many tiny
chunks to accumulate envelope/message overhead independently of the decoded-byte
bound. Each request now has an independent maximum of 64 outstanding output
events, in addition to its 256 KiB byte window. At 32 subscriptions that bounds
outstanding output to 2048 events. Credits retire only an exact prefix of emitted
bytes; partial byte consumption cannot release an entire message slot. Cancel
and independent work still progress while a tiny-event producer is credit-blocked.
Version 1.0 is rejected by 1.1 peers; these are development packages, with no
released compatibility promise. Package/build and protocol approval remain exact.

Elixir now has a bounded stream frame decoder, duplicate-key-rejecting JSON
decoder, strict native request/server DTO validation and a channel correlation
state machine. Frame lengths are checked before body accumulation. Parser depth
and integer-token lengths are checked before JSON parsing; collections, strings,
keys and integer ranges are bounded, and serialization size is checked before
allocating an escaped body. Only known scalar/variant values cross the channel;
base64 is canonical, padded and capped before decoded allocation. The native
fixtures round-trip through this decoder, including a disqualified command that
retains a real zero Exit without declaring success.

Correlation checks epoch/ID, acceptance and contiguous per-request sequences,
stream/operation pairing, receipt identity, output/credit totals and completed
upload totals. Acceptance supplies no running evidence. Completed subscriptions
remain charged until their output is consumed; a terminal alone cannot free an
unread observer mailbox and admit endless new subscriptions. Duplicate, stale,
gapped and mismatched messages fail closed. Both engine and protocol reject the
literal VM identifiers `.` and `..`, which would alias native storage roots.
Configuration target IDs also fit the existing backend-reference identifier
contract. Channel inspection omits commands, file data and receipt secrets.

The final 1.1 optimized macOS package is pinned at
`.local/embedded-port-proof/release-package-event-credit-final/package.json`, with
executable SHA-256 `c4e474b5c11585ed4d88f399475e10440d9044fbced28d21f55be2648ef962e7`
and asset SHA-256 `c36f073311c16123f965ca843996ac9ab17767c696a14e563a6f3eeae2d01a3d`.
Fresh intent/receipt/evidence under
`.local/embedded-port-proof/qualification-event-credit-final/` record actual
create/start, CPU/RAM/disks, numeric user, real command Exit, atomic 1,048,593-byte
file transfer, retained EOF recovery with a fresh epoch, deadline without Exit,
owned stop/delete, empty before/after inventory and empty helper stderr. This
ordinary native proof does not qualify the full process-fault campaign or Linux.

Validation passed 55 Rust checks (21 engine, 6 framing, 14 protocol, 14 helper),
4 source-integrity tests, formatting, Clippy and Rustdoc. All 663 Elixir
deterministic checks passed (29 live-runtime checks excluded), together with
zero xref cycles, strict Credo, ExDNA, Credence and test-environment Dialyzer
(zero errors). The 22 focused component checks
include the exact 1 MiB frame boundary and completed-but-unconsumed subscriptions.
The actual Port owner/supervisor, runtime result translation, durable store
bindings/intent/recovery, upstream mutation fencing, full fault/package-consumer
qualification and release delivery remain required. These pure channel components
do not enable public embedded admission or start a helper from the application.

## Supervised Elixir OS Port owner — October 10, 2026

`SmolBox.Embedded.Port` now implements the asynchronous bridge against a real OS
Port. Startup hashes the approved package manifest and executable in a linked
worker under a finite handshake budget, rejects symlinked package paths, writes
a private 0600 helper configuration, and opens the executable directly without
a shell. Dynamic-loader overrides are cleared and helper stderr stays separate
from framed stdout. Application startup remains inert; the embedded supervisor
must be started explicitly. One owner is registered per BEAM node, while the
native account lock fences authority across BEAM nodes/processes.

The owner approves the exact protocol/package/domain/capability/limit tuple.
Fresh helpers accept inspections only until a controller has bound its durable
domain, reconciled retained assignments, and explicitly activated mutations.
The activation callback checks the exact binding; it does not itself perform
store transactions. Create requests must match approved artifact and resource
catalogs before dispatch. Remaining budgets include local admission and send
queue time. Bounded data queues leave separate capacity for approval, credit,
cancel and shutdown controls. Nonblocking Port sends retain queued requests when
the driver is busy; known unsent deadlines cannot acquire native dispatch evidence.

Caller and observer monitors are independent. Losing one requests cancellation
only for its operation, with finite grace and output draining. Byte/event credit
is returned after consumption, completed subscriptions stay charged until unread
output is acknowledged, and discarded output cannot acknowledge a previously
forwarded unread prefix. File uploads have declared total reservations, bounded
chunks/offsets, and completion requires every byte to have been sent. Native
terminals preserve their actual outcome separately from a bridge error that may
disqualify completion (such as exceeding response allowance). Channel loss never
fabricates a native terminal or Exit and never replays a request.

Helper loss marks this owner unavailable and retains unread charges. Once those
are consumed, a confirmed helper exit permits bounded exponential restart and a
fresh reconciliation barrier. An unconfirmed exit quarantines the owner rather
than launching another helper on that authority. Unexpected owner death is
resolved by the caller's monitor; supervision restarts without replay. One
separate cleanup monitor per owner removes its private helper config even after
an untrappable owner-process kill, holding only the current directory across
helper restarts. This does not cover whole-BEAM process loss.

Thirteen deterministic OS Port tests use a Python fixture that never loads the
SDK or creates a VM. They cover exact approval/reconciliation, package tampering,
binary stdout/stderr and Exit, byte/event credit, unread terminal output,
preadmission deadlines, response limits with preserved native Exit, independent
caller/observer death, helper restart without replay, malformed sequencing,
oversized headers and partial EOF, bounded uploads, unconfirmed-exit quarantine,
and supervised owner death. Two outbox and two added channel checks cover
reserved control progress, bounded coalesced credit, unsent retirement and
preserved unread charges after channel loss.

The actual macOS arm64 package proof ran through this Elixir owner using
`scripts/embedded-port-proof.exs`. Evidence is saved under
`.local/embedded-port-proof/qualification-beam-owner-cleanup-final/`; the log is
`.local/embedded-port-owner-native-cleanup-final.log`. The exact optimized signed
1.1 helper remained SHA-256
`c4e474b5c11585ed4d88f399475e10440d9044fbced28d21f55be2648ef962e7`,
with approved manifest SHA-256
`fb85c9293823fb7cffac2dda265e059461297b9bf6f5cafcb24e44d7c23451b1`.
Using the existing enrolled domain and approved offline fixture, the proof saved
intent before creation and receipt before start, observed actual CPU=1, UID=65534,
environment/workdir and separate stderr, and retained real Exit=7. A binary
1,048,593-byte write/read had SHA-256
`6421abc875ac81a86d58d53f269fd5a9a19a78b4619ee3ca76654fbb0b4fe5fc`.
After both graceful helper shutdown and forced BEAM owner death, a fresh helper
observed the owned VM stopped and recovered its file after explicit activation
and start. A finite command deadline retained no invented Exit; subsequent
verified stop/delete returned missing. Before/after native inventory was empty,
and a separate process check found no owned helper/VMM process remaining.

Runtime backend/result integration, selective durable domain/receipt schema,
atomic intent and reservation fencing, durable restart recovery, expected-record
checks inside upstream mutation locks, Linux qualification, whole-BEAM/helper/boot
faults, independent package consumers and release delivery remain required.
This milestone does not satisfy the phase-4 mixed-runtime exit gate or enable
public embedded admission; those depend on the remaining runtime/store work.

Validation passed all 680 deterministic Elixir checks (29 live-runtime checks
excluded). The final `mix ci` run passed formatting, dependency checks,
warning-free compilation, zero xref cycles, strict Credo, ExDNA with no clones,
Credence and test-environment Dialyzer with zero errors. ExDoc generation passed
without warnings. After the cleanup-monitor change, the 23 focused owner/outbox/
channel checks and the actual native proof passed again before the final full CI
run. Logs are `.local/embedded-port-owner-ci-cleanup-final.log` and
`.local/embedded-port-owner-docs-final.log`. No HTTP path or native SDK/package
source changed in this milestone.

## Native record schema milestone — October 10, 2026

Selective schema v16 now represents the embedded target/domain binding, immutable
creation intent and native receipt evidence. Intent contains the approved prepared
artifact, resource profile, owner token and incarnation generated before a future
atomic reservation write. Bridge selection, helper epoch and runtime handles are
excluded. Native evidence uses no fabricated HTTP creation timestamp; running
observations require PID/birth evidence, while a verified VMM restart can preserve
the same full receipt. Material identity changes cannot match the saved incarnation.

Record validation binds target, domain, name, ownership and allocations together
and rejects capabilities outside the first native release. Retained command
attachment inherits the machine's assignment and receipt through the existing
transaction function, without acquiring a second resource reservation. Assignment
fields cannot be patched through execution state transitions. Inspect output
redacts native ownership evidence.

HTTP records still use their existing selective v1–v15 envelopes, with new nil
fields omitted on write and restored on read. Historical envelopes reject native
fields, including explicit nil keys, and older readers reject the unknown v16
prefix. The frozen offline fingerprint remains unchanged. Four representative
HTTP v2/v5 initial and assigned records matched predecessor `39a6726` byte for
byte when both encoders ran within one BEAM. Separate-BEAM comparisons preserved
prefixes and decoded terms but did not produce identical ETF bytes; that probe
does not establish cross-process byte determinism. Probe evidence is under
`.local/embedded-native-codec-byte-compatibility/` and its adjacent same-VM log.

All 687 deterministic Elixir checks passed (29 live checks excluded), along with
the full `mix ci` formatting, compilation, xref, Credo, ExDNA, Credence and Dialyzer
checks. Seven native codec checks cover fresh-BEAM decoding, legacy downgrade
rejection, receipt identity, retained attachment and unsupported shapes. The
focused checks and strict Credo passed again after refining the attachment test.
Development-environment ExDoc generation passed with warnings treated as errors
after documenting the native types referenced by public record types.
Evidence: `.local/embedded-native-schema-ci-second.log` and
`.local/embedded-native-codec-tests-attached-final.log`, with documentation output
in `.local/embedded-native-schema-docs-dev-final.log`.

This completes the phase-5 data model and codec milestone, not its exit gate.
Store capability negotiation, atomic domain binding and reservation/intent writes,
dispatch/result persistence, runtime backend integration and durable restart
recovery remain required. Public target admission remains HTTP-only. All shared
readers and projection writers must be upgraded before accepting native records;
rollback to older readers while any native records or tombstones remain is
unsupported. No native SDK or package source changed in this milestone.

## Atomic native enrollment and reservation milestone — October 10, 2026

The memory adapter and shared PostgreSQL/Ecto example now implement the optional
`bind_backend/3` callback and advertise `backend_bindings: 1`. Enrollment records
HTTP or the exact embedded target/domain binding, independently of bridge choice
and helper epoch. Repeated enrollment is idempotent. Assignments and released or
deleted tombstones fence changes of kind/domain; native domain generations cannot
be enrolled under a second target and create a duplicate capacity pool. An empty
target can change only after the caller establishes controller/native quiescence.

Both disposable and retained reservation transactions accept a native allocation
containing the immutable creation intent. They require the matching enrolled
binding and save intent, name assignment and capacity together. Existing HTTP
three-element allocations remain supported, but fail on a native binding. Local
volume admission rejects native targets. Native retained command attachment
continues to inherit its owning assignment and takes no additional reservation.
Shared native conformance checks verify that an unknown retained command keeps
its slot and capacity until explicit matching stopped evidence resolves the slot;
the command remains unknown with no invented result, and the stopped VM remains
fully reserved. These checks use synthetic receipt observations to test store
policy, rather than claiming live native recovery qualification.

PostgreSQL migration `20261010000000_backend_bindings.exs` adds the binding ledger
with kind/generation constraints and a unique native domain within the partition.
Enrollment and every reservation use the existing partition transaction lock.
Enrollment authenticates bounded pages of every assigned payload and projection,
including tombstones omitted from operational maintenance. A missing binding row
cannot reinterpret native history as HTTP: exact enrollment can be restored from
authenticated assignments, but another kind/domain and legacy allocation fail.
A missing table or unreadable assignment fails closed.
Another target also cannot claim a domain whose ledger row was lost: enrollment
authenticates other assigned authorities in bounded pages before accepting that
domain generation. The partition remains the sole store/capacity authority for
each physical worker; choosing another partition is unsupported.
Rollback rejects a ledger containing native bindings; all controllers/readers and projection writers must
upgrade before enrollment. Existing v16 records and tombstones also prevent safe
rollback to older readers, even if a binding row is removed administratively.

The memory binding ledger is separately bounded by its configured record limit.
Admission failure from capacity or encoded-byte exhaustion preserves the original
record, assignment index and usage. PostgreSQL injected transaction failures roll
back binding enrollment and native intent with their resource/name projections.
A fresh BEAM authenticated and decoded the committed native assignment, read the
same reservation and reenrolled the same binding. A 101-tombstone test discovered
conflicting authenticated history beyond the first page. No native VM was created
by these store tests.

All 694 deterministic root checks passed (29 live checks excluded), along with
full `mix ci` formatting, warning-free compilation, zero xref cycles, strict
Credo, ExDNA, Credence and Dialyzer. The PostgreSQL suite passed 88 checks (29 live
checks excluded) against a fresh private PostgreSQL 17.11 cluster with all
migrations applied. After extending native retained-command coverage, the seven
native memory checks and thirteen existing memory-store checks, plus ten
PostgreSQL backend checks, passed again. PostgreSQL
example quality checks passed compilation, Credo, zero clones and Dialyzer;
development ExDoc generation passed with warnings treated as errors. Evidence is
`.local/embedded-store-ci-final.log`, `.local/embedded-store-focused-final.log`,
`.local/embedded-store-postgres/full-tests-domain-final.log`,
`.local/embedded-store-postgres/focused-final.log`,
`.local/embedded-store-postgres/quality-domain-final.log` and
`.local/embedded-store-docs-final.log`.

Runtime capability negotiation, native backend/result routing, dispatch intent
and terminal persistence, observational recovery, unknown-command recovery and
the remaining native/release qualification gates are still required. Public
embedded target admission remains disabled; this milestone does not satisfy the
phase-5 recovery exit gate.

## Record-scoped native backend milestone — October 10, 2026

The internal embedded backend now translates the common lifecycle, foreground
command and guest-file operations into the approved native DTOs. Managed runtime
call sites bind references to the validated assigned record before these
operations. Binding checks target, domain, approved artifact/profile and saved
ownership evidence. Creation uses the previously reserved immutable intent;
subsequent operations require its saved receipt. An intent without a receipt
cannot authorize inspection, infer a material digest, or adopt an existing VM.
Cross-kind, domain and package mismatches fail before helper submission.

The bridge consumer monitors the original owner PID before checking its health
and exact package/domain identity. It bounds health, submission, uploads, output
consumption and callbacks by the remaining operation deadline, acknowledges only
consumed chunks and cancels only its own request. Caller death kills its consumer;
observer death triggers owner cancellation. A stalled owner or callback cannot
hold the caller indefinitely, and a replacement owner never receives a replay.

Native observations preserve receipt and actual PID/birth evidence without
inventing HTTP creation timestamps. Native output remains byte exact. A
disqualified command with a real Exit returns the typed error alongside a
truncated result containing the actual Exit and consumed output; managed
observation persists both. Unknown commands have no fabricated result. File
success requires matching byte counts and native atomic completion evidence.
The native command aggregate argv/environment bound is checked before generating
an assignment, and unsupported first-release features fail before dispatch.

All 706 deterministic root checks passed (29 live checks excluded), including
12 focused native backend cases and the existing HTTP regressions. Full `mix ci`
passed formatting, warning-free compilation, zero xref cycles, strict Credo,
ExDNA, Credence and Dialyzer. The prior Port, config and codec regression subset
also passed all 27 checks. These OS-Port fixture tests open no SDK or native VM.
Evidence: `.local/embedded-backend-tests-third.log`,
`.local/embedded-backend-port-regression.log` and
`.local/embedded-backend-ci-first.log`.
Development ExDoc generation passed with warnings treated as errors; its log is
`.local/embedded-backend-docs-final.log`.

A separate real macOS arm64 proof used the new adapter, the memory store's atomic
native reservation and the signed package with manifest digest
`fb85c9293823fb7cffac2dda265e059461297b9bf6f5cafcb24e44d7c23451b1`.
Private fsynced v16 intent preceded create, and saved receipt preceded start.
The guest reported CPU=1, the supplied environment, `/workspace` and UID 65534;
Exit 7 and stderr were preserved. A 1,048,593-byte binary file matched digest
`6421abc875ac81a86d58d53f269fd5a9a19a78b4619ee3ca76654fbb0b4fe5fc`
before and after stop/start. Explicit stop/delete and missing observation
completed; inventories were empty before and after. The backend deliberately
left capacity reserved for the store/controller to release. An earlier proof
correctly rejected that file above the default 1-MiB approval and cleaned up;
the passing run explicitly approved a 2-MiB profile. Local evidence and the
probe source are `.local/embedded-backend-proof-real-third/`,
`.local/embedded-backend-native-proof-third.log` and
`.local/embedded-backend-proof.exs`. A fresh BEAM decoded both saved intent and
receipt records and checked their domain/name association; evidence is
`.local/embedded-backend-native-fresh-beam.log`. This is an adapter proof, not durable runtime
restart or package-consumer qualification.

Public embedded target admission remains disabled. Runtime negotiation and
enrollment, mutation activation after reconciliation, durable dispatch/result
recovery and conservative lost-create resolution still require integration.
Expected-record verification inside upstream mutation locks, whole-BEAM/helper
loss, Linux qualification and the independent packaging/licensing/release gates
also remain open. Rustler and Kubernetes remain future additive implementations;
this milestone changes no native SDK or signed package source.

## Checked SDK lifecycle and shared operation locks — October 10, 2026

Owned patch `0003-checked-machine-lifecycle.patch` adds checked start, stop and
delete SDK entry points. A trusted verifier receives the fresh record after the
SDK acquires its runtime name lock and cross-process source-operation lock.
Verification runs before cached-handle changes, signals, launches or storage
deletion. Existing SDK lifecycle entry points retain their default behavior.
The patch is checksummed in `native/vendor/source.json`; bootstrap regenerated
and verified the complete owned SDK tree. The research checkout remained clean.

The engine uses these entry points to recheck receipt/material identity,
incarnation marker, expected observed state, clone dependencies and actual
running PID/birth evidence. A mismatched live cached PID is identity-unknown,
rather than stopped evidence. Verifier rejection is explicitly not dispatched;
later SDK failures remain uncertain. Commands and files retain the shared source
lock through bounded native I/O, while cancellation continues through independent
sockets. These locks serialize cooperating lifecycle/fork/resize paths; arbitrary
raw account-owner writes and independent/unpatched CLI operation are not qualified
by this change.

A deterministic barrier test held the SDK source lock, changed material after
the engine's observation, and released the lock while each of start/stop/delete
was waiting. All three refused with ownership/not-dispatched evidence, retained
the row and incarnation directory, and launched no child. A second check changed
state while preserving material receipt identity and proved delete refusal.
All 57 Rust tests and four Python source-integrity tests passed, along with owned
workspace formatting, Clippy with warnings denied and Rustdoc with warnings
denied. The pinned upstream dependencies still emit their existing Rust 1.99
atomic `fetch_update` deprecation warnings. Evidence is
`.local/embedded-checked-lifecycle-final.log`.

A fresh optimized macOS arm64 build used a private copy of approved libkrun
libraries. The resulting ad hoc signed package has source-manifest digest
`33fbf228f3abd6bdd052f49db91d424b194a3af70831cea0f0a12bd23dfd1338`,
executable digest
`c1641168375a0b470ca787a87477bb222be5d3e1e7e9eedb443d45e6bcb1d511`
and package-manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
Build/package evidence is `.local/embedded-checked-release-build.log` and
`.local/embedded-checked-package-build.json`; the package lives under
`.local/embedded-port-proof/release-package-checked-lifecycle/`.

The real Elixir Port proof passed against this exact package: actual CPU/env/
workdir/UID and Exit 7, byte-exact 1,048,593-byte files, retention after graceful
owner shutdown and forced owner death, fresh helper epochs, and a deadline
without fabricated Exit. Explicit stop/delete completed and inventories were
empty before/after. Evidence is
`.local/embedded-port-proof/qualification-checked-lifecycle/evidence.json` and
`.local/embedded-checked-beam-proof.log`. The record-scoped adapter proof also
passed against this package, saving private fsynced v16 intent/receipt, preserving
files through stop/start, deleting only its owned receipt and leaving capacity
reserved for explicit controller release. Its evidence is
`.local/embedded-checked-backend-proof-real/` and
`.local/embedded-checked-backend-proof.log`.

This closes the tested stale-check window across waiting for the SDK mutation
lock. It does not complete the full interference/fault qualification gate or
enable public native admission. Runtime negotiation, reconciliation and durable
recovery remain required, along with broader independent CLI/cache interference,
whole-BEAM/helper loss, Linux and package-consumer/license/release qualification.

## Assignment recovery pages and internal target routing — October 10, 2026

Stores now expose optional `backend_assignments/4` with `backend_recovery: 1`.
Memory and the shared PostgreSQL adapter return authenticated execution, machine
and volume records, including released/deleted tombstones and retained commands.
Reads do not claim records, change accounting, or generate ownership evidence.
The keyset cursor scans the authority's complete corpus before filtering for the
requested worker; empty pages can advance the cursor. PostgreSQL authenticates
payloads and all projections, so missing/displaced worker IDs and unreadable
unassigned records fail closed instead of disappearing from recovery. SQL uses
byte-order collation matching the Elixir cursor order.

Pages are bounded to 1–100 records; PostgreSQL reads at most limit+1 candidates
per record kind. A future native recovery controller should request limit=1 to
bound full-record buffering, follow empty advancing pages, renew its worker
lease, and establish dispatch quiescence before activation. Multiple pages do
not constitute a snapshot. This callback supplies evidence; it does not itself
implement reconciliation or recovery policy.

Embedded approvals now normalize into the internal target abstraction. Pure
support checks and machine-spec conversion use the approved artifact/profile;
allocation generates creation intent before the store atomically reserves it.
Execution and retained-machine dispatchers use this allocation path. HTTP keeps
its existing allocation and client behavior. Public native runtime construction
still rejects admission until supervised reconciliation and helper epoch fencing
are integrated. Normalization alone launches no helper.

Five deterministic OS-Port peer tests cover pure approval/allocation, the public
admission gate, disposable execution and absence-based capacity release, owner
loss without command replay, and retained commands inheriting receipt/intent
without a second capacity reservation. These checks exposed and fixed two
integration gaps: native inspection errors must use the persisted `:inspect`
error vocabulary, and native disposable cleanup must stop and verify the owned
incarnation before deletion. The peer now refuses running-machine deletion to
match the engine's contract. HTTP cleanup retains its prior behavior.

`mix ci` passed 714 checks (4 doctests, 6 properties, 704 tests), with 29 native
lab tests excluded. Formatting, warnings-as-errors compilation, cycle checks,
Credo, duplication checks, Credence and Dialyzer passed. Evidence is
`.local/embedded-target-ci-final.log`; development ExDoc passed with warnings
treated as errors in `.local/embedded-target-docs.log`. PostgreSQL passed 93
tests with 29 lab exclusions, including assignment paging, projection tampering
and fresh-BEAM reading. Its quality checks passed; evidence is
`.local/embedded-store-postgres/recovery-pages-full.log` and
`.local/embedded-store-postgres/recovery-pages-quality-second.log`. The private
socket-only PostgreSQL cluster was stopped after qualification.

A real macOS arm64 internal dispatcher proof used the existing signed package
with manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
The memory-store wrapper fsynced private v16 creation intent before create and
saved receipt before start. The guest reported CPU=1, supplied environment,
`/workspace`, UID 65534, stderr and actual Exit 7. The dispatcher then stopped,
verified stopped identity, deleted, observed absence and released capacity.
The final assignment page retained the completed tombstone, and native
inventories were empty before and after. Probe source and evidence are
`.local/embedded-runtime-proof.exs`, `.local/embedded-runtime-native-proof.log`
and `.local/embedded-runtime-proof-real/`. This uses explicit internal activation
and an ephemeral store; private fsynced snapshots do not qualify durable runtime
restart. No native SDK, engine source or signed package changed in this milestone.

The next integration gate remains supervised store negotiation/enrollment,
complete assignment reconciliation and activation, and fencing delayed old tasks
against a fresh helper PID/epoch. Durable uncertain-result and lost-create
recovery, pre-reservation guest-user/artifact qualification, whole-BEAM/helper
loss, independent CLI/cache interference, Linux and package-consumer/license/
release qualification remain open. Public native admission remains disabled.

## Fencing delayed work across helper restart — October 10, 2026

Managed execution and retained lifecycle work now capture the selected native
owner PID and helper epoch before durable mutation/dispatch intent. The task
keeps this operational pin through preparation, async observation and cleanup;
neither a dead owner nor an unavailable capture can resolve a replacement later.
Work already assigned to HTTP does not probe native owners. Capture is bounded,
and health calls need no cancellation drain because they admit no native request.
HTTP references remain unchanged and issue no capture-time transport request.

The shared bridge contract adds fenced submission and activation arities.
Submission validates the expected epoch atomically inside the owner before
allocating request IDs or outbox space. This closes the race between health
validation and submission when the same owner process has restarted its helper.
Activation can similarly reject reconciliation completed against an old epoch.
The unfenced arities remain explicit low-level development interfaces; managed
dispatch uses the fenced callback. Epochs and owner PIDs stay in runtime
references, separate from durable receipts, assignment identity and store leases.
These changes add no Rustler or Kubernetes implementation.

Deterministic store barriers pause after saved exec intent, then either replace
the owner process or restart its helper inside the same owner. Resuming the old
task sends no new request and retains unknown outcome/reservation. Another test
pauses saved retained start intent: owner replacement leaves the operation
uncertain and its existing receipt and reservation intact. An unavailable pin
cannot bind to a later owner. Bridge tests reject stale activation/submission
even after the fresh helper is ready, without consuming request IDs. A separate
test verifies that HTTP-assigned work never contacts an unresponsive native owner.

A real macOS arm64 proof used signed package manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
Private fsynced v16 exec intent preceded the paused dispatch. Graceful owner
replacement stopped the owned VM and produced a fresh helper epoch. Receipt-bound
inspection observed stopped state without starting the VM. After explicit
activation, resuming the old task did not advance the fresh channel's request ID;
its result stayed unknown, without Exit, and full capacity remained reserved.
A fresh internal recovery task observed stopped state and confirmed termination
without replay. Explicit receipt-bound disposal, observed absence and store
release then cleaned up the proof. Inventories were empty before and after.
Source/evidence are `.local/embedded-epoch-selected-proof.exs`,
`.local/embedded-epoch-selected-native-proof.log` and
`.local/embedded-epoch-selected-proof-real/`. A fresh BEAM decoded the saved
dispatch, unknown, observed-stopped and released v16 records and verified their
unchanged assignment identity; evidence is `.local/embedded-epoch-fresh-beam.log`.
This is an ephemeral-store internal
fault proof; it does not qualify durable runtime or whole-BEAM restart.

The full project checks passed 719 checks (4 doctests, 6 properties, 709 tests),
with 29 native lab tests excluded. Formatting, warnings-as-errors compilation,
cycle checks, Credo, duplication checks, Credence and Dialyzer passed; evidence is
`.local/embedded-epoch-selected-ci-final.log`. Development ExDoc passed with
warnings treated as errors in `.local/embedded-epoch-selected-docs-final.log`.
No native SDK, engine source, package or PostgreSQL schema changed.

Public native admission remains disabled. Supervised store negotiation/enrollment,
target-specific dispatch quiescence, complete assignment reconciliation and fenced
activation still need integration. The epoch pin prevents old native dispatch;
it does not itself provide store snapshot/quiescence or resolve an uncertain
creation without a saved receipt. Durable recovery, pre-reservation guest-user/
artifact qualification and the remaining whole-BEAM, independent interference,
Linux and package-consumer/license/release gates remain required.

## Supervised native reconciliation — October 10, 2026

The internally configured runtime now owns its native supervisor. Before launching
any helper it negotiates `backend_bindings: 1`, `backend_recovery: 1` and
`managed_machines: 1`, verifies their callbacks, and enrolls the exact domain binding.
The current SDK permits one native account domain per BEAM. HTTP-only startup
remains inert, and public native configuration still rejects admission while the
remaining first-release gates are completed.

The coordinator freezes native dispatch from initialization. Recovery captures the
owner PID and helper epoch, waits for tasks that could use that target, closes the
owner's mutation gate, and waits for pending subscriptions to drain. It renews
the worker lease and reads the complete store authority one record per page,
including tombstones. Empty filtered pages may advance the cursor; malformed or
non-advancing cursors and store errors keep admission closed. Activation checks
the original epoch and an empty pending set. It never silently binds an old task
to a replacement helper.

Recovery inspects only saved full receipts. Uncertain creation without a receipt
stays unverified and reserved, without a helper request or label adoption.
Interrupted preparation/dispatch becomes unknown without command replay or
fabricated Exit; unknown retained commands keep their slot blocked. Stopped
retained storage stays stopped and reserved, and missing retained storage stays
missing and reserved. Verified absence can complete disposable cleanup and
release its reservation. Existing results and partially saved artifacts are
classified without replaying output collection. Concurrent record changes fail
closed and require a fresh scan.

Normal helper loss restarts inside its Port owner. Exhausting the target's owner
restart budget stops that subtree and leaves the target unavailable; its temporary
supervisor child prevents restart escalation from exhausting the runtime's budget
or interrupting HTTP work. Recovery of that exhausted subtree requires an explicit
runtime restart after operator quiescence. It is not an automatic ownership
transfer to another domain.

Deterministic supervised tests cover empty authority activation, capability
rejection before launch, stopped and missing retained storage, lost creation
receipts, unknown retained command slots, coordinator restart, malformed authority
pages, and helper loss alongside healthy HTTP execution. Repeated unexpected
owner deaths exhaust only the native target's budget; the same HTTP coordinator
continues accepting and completing work. Bridge tests verify stale quiescence
rejection and that unread terminal output prevents fenced activation until drained.

A real macOS arm64 proof used signed package manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
The actual supervised runtime automatically reconciled and activated its helper.
Execution observed Exit 7 with CPU, environment, workdir and numeric UID witnesses,
then observed stopped/deleted absence before capacity release. Retained creation,
explicit start/stop and graceful owner replacement preserved the full receipt,
assignment and reservation, with fresh reconciliation observing stopped storage.
Explicit deletion then observed absence and released capacity. Inventories were
empty before and after. The proof waits separately for cleanup because execution
`await` can return its result before cleanup completes. It refreshes the retained
record version before deletion rather than reusing a version saved before fsync.

Evidence is `.local/embedded-supervised-proof.exs`,
`.local/embedded-supervised-native-proof-passed.log` and
`.local/embedded-supervised-proof-passed/`. Six private fsynced v16 snapshots
also decoded in a fresh BEAM with unchanged assignments, receipts, retained
reservation and verified releases; evidence is
`.local/embedded-supervised-fresh-beam.log`. This is internal ephemeral-store
qualification, not durable or whole-BEAM restart qualification.

The full project checks passed 729 checks (4 doctests, 6 properties, 719 tests),
with 29 native lab tests excluded. Formatting, compilation with warnings as
errors, cycle checks, Credo, duplication checks, Credence and Dialyzer passed in
`.local/embedded-supervised-recovery-ci-final.log`. The PostgreSQL example passed
93 tests, with 29 lab tests excluded, using the private socket-only test cluster;
evidence is `.local/embedded-store-postgres/supervised-recovery-tests.log`. That
cluster was stopped afterward. Development ExDoc passed with warnings treated as
errors in `.local/embedded-supervised-recovery-docs.log`. No native SDK, engine,
signed package or PostgreSQL schema changed.

Supervised reconciliation is integrated, but public admission remains disabled.
Pre-reservation artifact/geometry and guest-user qualification, native optional
API rejection and explicit resolution/inventory APIs, durable fresh-BEAM and
whole-BEAM fault qualification, independent interference, Linux evidence and
package-consumer/source/license/release gates remain required. This milestone
does not claim a usable public Port release.

## Native API routing and explicit receipt resolution — October 10, 2026

Retained-machine diagnostics now use backend references and pure operation
capability checks. Native logs, measurements, image inventory and disk expansion
return typed unsupported failures before helper calls or store mutations. Retained
submission checks the assigned native target's complete command/spec support
before accepting a command or claiming its slot, including stdin/background
rejection. HTTP clients, transports and supported operation behavior remain intact.
Worker lookup uses logical target IDs rather than HTTP client fields. Native
worker reports retain real store accounting and a typed unsupported live-capacity
error instead of inventing host measurements.

Native health reports the approved package identity/digest, Port selection,
protocol 1.1, engine and bridge limits, capabilities and owner-bound lifetime.
It omits helper epochs, process identities and machine receipts. Package preflight
reporting describes the approved package handshake; it does not qualify the
remaining guest-user or artifact/geometry admission gates.

`audit_worker/3` has a native branch that pages the complete authoritative record
corpus and observes saved full receipts. Each native page examines at most one
full record, including released/deleted history; an empty filtered page can advance
the opaque tuple cursor. Reports omit creation tokens, package paths, commands
and content. They distinguish owned, absent, unverified, conflict, cleanup conflict
and unavailable findings. Shared SDK inventory is never enumerated, so native
`foreign_count` is nil. No-receipt records remain unverified without a helper
request. Malformed records/cursors fail closed. The existing HTTP namespace-list
report and cursor behavior remain supported.

Explicit native `Machines.resolve/4` with a saved receipt captures its original
owner/epoch, freezes target dispatch, drains the bridge and renews the worker
lease before observation. A monitored local authority lock serializes this path
with automatic reconciliation. Caller death releases the lock but leaves dispatch
frozen until a complete successful scan; unrelated targets keep serving. The
coordinator rejects activation by a caller that does not hold that authority.
Worker control reporting now honors this native freeze rather than overwriting
it with cached ready health. Recovery and resolution select their bridge through
the shared context, preserving an additive Rustler integration point.

Stopped resolution verifies the same full incarnation and clears the blocked
command slot while preserving its unknown outcome and missing Exit. Deleted
resolution observes receipt-bound absence before releasing retained capacity;
it sends no delete. Historical commands with complete cleanup no longer own a
slot, and stores correctly reject new claims on them. Recovery still validates
and observes those receipts but leaves their completed history unchanged. This
fix permits readmission after explicit unknown-command resolution. Safe typed
recovery errors are retained internally for diagnosis.

Sixteen deterministic supervised cases now cover these API paths, read-only
inventory, accounting, rejected unsupported submissions, receipt-less rejection,
authority exclusivity/death, stopped resolution, verified missing resolution,
and helper/owner/coordinator loss alongside HTTP. The complete project checks
passed 736 checks (4 doctests, 6 properties, 726 tests), with 29 native lab cases
excluded, plus all formatting, compilation, cycle, Credo, duplication, Credence
and Dialyzer checks. Evidence is `.local/embedded-native-public-api-ci-final.log`.
The PostgreSQL example passed 93 contract tests with 29 lab cases excluded in
`.local/embedded-store-postgres/native-api-tests.log`; its private socket-only
cluster was stopped afterward. Development ExDoc passed with warnings as errors
in `.local/embedded-native-public-api-docs-final.log`.

A real macOS arm64 proof used the unchanged signed package manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
It exercised the actual supervised execution and retained stop/start path,
receipt-bound inventory, native health/accounting and unsupported diagnostics.
After dispatch intent was saved and fsynced by the private snapshot wrapper, a
paused retained dispatch lost its owner. Resuming the old task left an unknown command without
Exit and retained the blocked slot and complete reservation. Fresh reconciliation
observed stopped storage. Explicit stopped resolution cleared the slot while
preserving the unknown command; subsequent readmission left its cleanup history
unchanged. Explicit deletion observed absence before release. Inventories were
empty before and after. Source and evidence are
`.local/embedded-native-api-proof.exs`, `.local/embedded-native-api-proof.log`
and `.local/embedded-native-api-proof-real/`. Ten private fsynced v16 snapshots
decoded and round-tripped in a fresh BEAM, preserving unknown outcome, receipt,
assignment and verified accounting; evidence is
`.local/embedded-native-api-fresh-beam.log`. This remains internal ephemeral-store
qualification, not a durable runtime or whole-BEAM restart claim.

Public native admission remains disabled. Receipt-less native resolution currently
returns unsupported before mutation; a qualified intent-bound absence observation
is required to resolve uncertain creation without inventing material identity or
adopting labels. Pre-reservation artifact/geometry and guest-user qualification,
durable fresh-BEAM/whole-BEAM faults, broader independent interference, Linux and
package-consumer/source/license/release gates remain required. No native SDK,
engine, wire protocol, signed package or PostgreSQL schema changed here.

## Durable native recovery and BEAM dispatch-intent loss — October 10, 2026

The encrypted PostgreSQL host example now has reproducible staged native runtime
proofs in `examples/durable_host/scripts/embedded-recovery-proof.exs` and
`embedded-recovery-kill.py`, with instructions in
[the durable proof guide](embedded-port-durable-proof.md). They use actual durable
store capabilities, SQL transaction commits, authenticated ciphertext/projections,
v16 intent and receipt records, target enrollment and the signed native package.
Every phase refuses reuse and saves private fsynced evidence. No memory store or
artifact-store persistence is substituted; this proof has no saved outputs or
artifact-store inputs. The internal normalized-target construction remains
explicitly separate from gated public admission.

The first three-process sequence executed a disposable command with real Exit 7,
confirmed absence/release, created and started a retained machine, and paused an
attached command after its SQL dispatch-intent commit and before native send.
Owner replacement fenced the old task and persisted unknown without Exit, a
blocked slot and the complete reservation. A separate BEAM automatically
reconciled the saved assignment and same stopped receipt, preserving one reserved
slot and the unknown command. Explicit stopped resolution cleared the slot while
leaving the unknown outcome intact. Only after that resolution did an explicitly
started new command verify the persistent guest replay marker was absent.
Explicit stop/delete confirmed absence and released capacity. A third BEAM
preserved deleted receipt/assignment evidence and unchanged historical unknown
commands with zero reservation. Inventories matched their empty baseline.

The second sequence left SQL in `dispatching` and the retained VM running at the
same committed-intent/before-send barrier. A separate Python runner verified the
still-live BEAM was its own direct child, sent SIGKILL only to that process and
recorded signal 9. It observed the original helper exit following owner loss;
it did not kill the helper or VMM. A fresh BEAM observed the same stopped full
receipt, classified the interrupted command unknown without Exit, preserved its
blocked slot and complete reservation, then completed the same explicit
resolution, no-replay marker check and verified deletion. A third BEAM again
preserved tombstones/history with zero capacity. This qualifies whole-BEAM
SIGKILL after committed exec intent and before native send. Kills around
create/start/result persistence, accepted exec and boot-time parent loss remain
separate unmet boundaries.

macOS arm64, Elixir 1.20.4 / OTP 29.0.6 and PostgreSQL 17.11 evidence used the
unchanged signed package manifest digest
`33cb3d38c7a80db56d590a41d01e8a68ca2f9645b0fb15fa75e7674c105464df`.
Private logs and snapshots are listed in the guide. A further fresh-BEAM SQL
audit proved both persisted commands still had `state: :unknown`,
`evidence: :unknown`, nil result and complete cleanup, matching their saved
post-resolution records exactly; both deleted machines retained absence evidence
and zero reserved slots. Its log is
`.local/embedded-store-postgres/durable-native-final-audit.log`.

`mix ci` passed 736 checks (4 doctests, 6 properties, 726 tests), 29 lab cases
excluded, with every configured analyzer and Dialyzer passing in
`.local/embedded-durable-native-ci.log`. Final formatting/Credo passed in
`.local/embedded-durable-native-credo-final.log`; development ExDoc passed with
warnings as errors in `.local/embedded-durable-native-docs.log`. PostgreSQL passed 93 contract
tests, 29 lab cases excluded, in
`.local/embedded-store-postgres/durable-native-contracts.log`. Python compilation
and both actual signal-runner/native sequences passed. The failed initial proof
attempt had already resolved its slot when a proof-script omission tried to
submit on a stopped machine; explicit saved-receipt disposal confirmed deletion
and released its reservation before the successful new sequences. No native
inventory sweep or synthetic Exit was used. The private PostgreSQL cluster was
stopped after verification.

Public admission remains disabled. Artifact/geometry and guest-user qualification
before reservation, qualified receipt-less intent-bound absence resolution,
remaining fault/interference boundaries, Linux evidence, fresh package consumers
and source/license/distribution/release gates remain required. No SDK, engine,
protocol, package or SQL schema changed in this milestone.

## Pre-reservation artifact and user qualification

Protocol 1.2 adds a receipt-less, streamless `qualify_creation` query and a
query-specific `qualified` terminal. The shared engine uses the same approved
artifact preparation as create: bounded digest-cache copy and rehash, footer/CRC,
bounded typed manifest, host architecture and resource policy. It then validates
the guest-user policy without touching VM records, VM directories, lifecycle locks
or native handles. Immutable digest-cache writes are allowed. Create independently
repeats the checks before VM mutation. The helper and Elixir owner both require an
exact approved catalog entry; query success supplies no receipt or Exit evidence.

Disposable and retained creation now qualify before atomic reservation. Retained
commands qualify before store acceptance or slot attachment. Explicit users must
be numeric UID or UID:GID below the u32 sentinel, on container packs only. Named
users and explicit VM-pack users are rejected. Existing native records keep their
structural user validation, so this narrower admission policy does not invalidate
historical v16 ciphertext or authorize replay. HTTP runtime qualification is a
no-op and the HTTP backend does not advertise the native query.

Permanent artifact validation/unsupported rejection persists a worker-less failed
execution with complete cleanup, or a worker-less retained-machine conflict,
without assignment, VM name or reservation. The saved error uses the existing
`prepare_artifact` operation so v16 codec atoms and SQL schemas remain unchanged.
Retained-command rejection writes no execution or attached slot. Unknown transport
outcomes cannot manufacture a command result. The query's maximum 30-second budget
includes helper queue time and cancellation grace; hard deadlines for stuck kernel
filesystem I/O are not qualified.

Deterministic cases cover failed qualification with no reservation/create, VM-pack
user rejection with no slot/exec, pure rejection of named/sentinel users,
historical named-user codec compatibility, and rejection of uncertain worker-less
conflict evidence. Rust contracts reject qualification streams/uploads, excessive
budgets and a qualified terminal satisfying exec. Native checks passed 60 Rust
tests plus four Python integrity tests, formatting, Clippy and Rustdoc in
`.local/embedded-qualification-native-check-final.log` (the pinned upstream
deprecation warning remains). `mix ci` passed 739 checks (4 doctests, 6 properties,
729 tests), 29 lab cases excluded, with all analyzers and Dialyzer passing in
`.local/embedded-qualification-ci-final.log`. PostgreSQL passed 93 contract tests,
29 lab cases excluded, in `.local/embedded-store-postgres/qualification-contracts.log`.
ExDoc passed with warnings as errors in `.local/embedded-qualification-docs.log`.

The rebuilt optimized, ad-hoc signed macOS arm64 package has manifest SHA-256
`57510c90cc95cf85039f65d032a39150aa89b60c5fcf7ad20c179e1c3d94edf2`,
executable SHA-256
`dc091d781ac9168892f9b39ef60f65f4228e56d46798b275adf6a63dec0bd652`
and assets SHA-256
`7c3c2edf7f243d2560fce6af3e90c3c66bdb85c845e367974bc822e6789d1f70`.
The SDK/source/patch pins are unchanged. An actual qualification-only helper proof
accepted numeric user 65534:65534, rejected names/sentinel UID and an approved
malformed pack, emitted no stream data, and left the empty SDK inventory unchanged;
private evidence is `.local/embedded-qualification-negative-proof/`. The native
API proof passed real execution, receipt inspection, explicit stopped resolution
and verified deletion in `.local/embedded-qualification-api-proof.log`.

Both tracked encrypted PostgreSQL three-BEAM sequences were rerun with this exact
1.2 package: owner replacement and whole-BEAM SIGKILL after committed exec intent
and before native send. They preserved the same stopped full receipt and unknown
slot, proved no replay, resolved explicitly, deleted with absence evidence and
released capacity. Fresh verification preserved tombstones and unchanged unknown
history. See the durable proof guide for the exact logs and process evidence.

Public admission remains disabled. Complete archive-asset validation and actual
disk geometry before reservation remain open: footer/manifest qualification does
not establish them. Receipt-less intent-bound absence resolution, remaining fault
and interference boundaries, Linux evidence, fresh package consumers and
source/license/distribution/release gates also remain required. The current user
policy qualifies numeric container users only; broader user resolution is deferred.

## Streaming pack contents and disk geometry before reservation

The shared engine now validates complete sidecar asset streams as part of the
existing pre-reservation qualification and independently during create. It
requires byte-zero sidecar assets, a contiguous manifest/footer with no undeclared
suffix, the full declared inventory with exact regular-file sizes, canonical
layer filenames and no duplicate/undeclared assets or outer file/parent conflicts.
Agent rootfs and OCI tar streams must parse completely. Headers, effective
GNU/local-PAX paths and link targets are checked before variable allocation;
compression must finish without truncation or hidden nonzero payload after tar
termination. Old-GNU sparse maps are validated and read virtually, without
extracting any files. Ext4 disk superblocks must describe nonzero geometry no
larger than admitted backing storage; VM manifests also retain the exact logical
size checks from the preceding milestone.

This is a streaming read through bounded buffers and metadata. It does not invoke
SDK extraction, layer mounting/post-processing, cache eviction, VM records,
directories or handles. The existing immutable digest-cache copy remains. Explicit
limits are 256 declared assets, 200,000 aggregate tar records, 128 GiB aggregate
apparent bytes across outer/nested archives, an independent 128 GiB outer decoded
stream, 4096-byte paths, 16 KiB extension metadata, 4096 sparse extents and bounded
sparse extension blocks, and an 8 MiB zstd window. Unsupported global-PAX/GNU
sparse-PAX forms and outer links fail before VM mutation. These checks establish
pack structure and backing geometry, not filesystem consistency, guest boot
success, every host extraction-layout edge or host quotas. Large/exhaustion and
adversarial platform qualification remains confined to the disposable Linux lab.

Added the tracked explicit artifact proof
`native/smolbox-port/tests/artifact_proof.py`. It verifies the actual approved
container pack and valid small synthetic container/VM manifest controls, then
rejects missing, duplicate and undeclared layers, invalid nested tar, wrong
declared size, hidden trailing data and fabricated VM disk geometry. Each case
is checked through both qualification and direct create: safe validation,
`not_dispatched`, no streams or receipt, and unchanged empty native inventory.
The synthetic VM controls qualify parsing/geometry only and are never booted.
The proof requires an explicitly selected zstd executable only for authoring
small fixtures; the helper has no new runtime executable dependency.

Native checks passed 68 Rust tests plus four Python integrity tests, formatting,
Clippy and Rustdoc in `.local/embedded-archive-native-check-complete.log`.
The decoded-byte exact-boundary check also passed in
`.local/embedded-archive-boundary-check.log`. SDK deprecation warnings remain
unchanged. Tar and zstd were already pinned transitive dependencies; adding them
directly to the engine changed only its lockfile dependency list. No SDK source,
patch, protocol, codec or SQL schema changed. `mix ci` passed 739 checks
(4 doctests, 6 properties, 729 tests), 29 lab cases excluded, with every analyzer
and Dialyzer passing in `.local/embedded-archive-ci.log`. PostgreSQL passed 93
contract tests, 29 lab cases excluded, in
`.local/embedded-store-postgres/archive-contracts.log`; ExDoc passed with warnings
as errors in `.local/embedded-archive-docs.log`.

The final rebuilt signed macOS arm64 package has manifest SHA-256
`3a6694c74bf811f8972e53fc1260ceb510353c5042b6db2464a7f27f602a30c0`,
executable SHA-256
`1c153a7bd7ecca9c21d42f20a113188d4fa8e01abda7eeb82840cf133a22f975`
and assets SHA-256
`2516920e8f2a65dcfbdf34c0526d9311c36b5f3ccc214e1f0f3cc54638cc3197`.
SDK/source/fixture pins are unchanged. The final artifact proof passed in
`.local/embedded-artifact-complete-proof.log` with private snapshots under
`.local/embedded-artifact-complete-proof/`. The real Elixir native API proof
passed Exit 7, applied CPU/env/workdir/numeric user, retained stop/start and owner
recovery, explicit unknown-slot resolution, verified deletion and capacity release
in `.local/embedded-archive-complete-api-proof.log`.

The encrypted PostgreSQL owner-replacement three-BEAM sequence was also rerun with
this exact package. It preserved the stopped full receipt and unknown slot,
proved no replay, resolved explicitly, deleted with verified absence and released
capacity. A third BEAM preserved the tombstone and unchanged unknown history.
Exact process/log evidence is in the durable proof guide. The prior SIGKILL
sequence's package identity remains distinct; this milestone does not extend its
evidence to a new package implicitly.

Public admission remains disabled. Live VM-mode pack boot/topology, remaining
format/extraction-layout and fault/interference boundaries, receipt-less
intent-bound absence resolution, Linux evidence, fresh package consumers and
source/license/distribution/release gates remain required.

## Live VM-mode pack milestone — October 10, 2026

The tracked `native/smolbox-port/tests/vm_pack_proof.py` now qualifies ordinary
live bare-VM packs on macOS arm64. The fixture-authoring Rust example builds a
seed from verified packaged templates and exports a stopped source through the
pinned SDK library while holding its source-operation and native-domain locks.
Export requires the saved full receipt; it adds no product export capability.
The helper imports the exported root and storage snapshots, boots the neutral
agent without executing the baked workload, applies one CPU, 512 MiB guest RAM
and two 1 GiB disks, and observes a real Exit 7. Both disk witnesses survive
retained stop/start and helper EOF; 3341 bytes of binary file I/O survive recovery.
Explicit VM command users are rejected before dispatch. Both saved receipts are
deleted with observed absence and inventory returns to its empty baseline.

Live SDK packs exposed two compatible layouts now accepted by admission: empty
structural `layers/` and `lib/` directories, and an omitted logical-size field
when a raw asset already has its full backing length. Structural directories
cannot replace a declared file; truncated disks still require explicit logical
size. Complete stream validation and admitted disk geometry remain required.

The final signed package manifest SHA-256 is
`2f21216070495a40b89e6346d512b5a15ee974d62af97a0a6e7b620739e49f40`,
with executable SHA-256
`e247421116a685ed516adc8b251b58e5c4cf5e2e8a356fe4238e0a17d11cf0f3`
and assets SHA-256
`a0652ae24e641036bde263433d01991e21225cb36c215bd70f77c1d91dd75cb4`.
SDK/source pins, protocol 1.2, codec and SQL schema are unchanged. The live proof
is recorded in `.local/embedded-live-vm-pack-proof-final/` and its sibling log.
Its seed SHA-256 is
`86d99073e62a570406add22b73040daaa72fddf6961e5362356429e04a3ab8f4`;
the exported pack SHA-256 is
`9d95407571ce4e885adda2024eba69b59c0031727de4bde0cf05542c58a12590`.
The authoring example SHA-256 is
`c2a6318d4f30fbd52807a5485ad7a1ee66a85d9a0d257712b0c6824cb2b8e2c8`.

The durable proof now records `--guest-mode vm` and uses the agent's default
user; existing container proofs keep their numeric user. The encrypted
PostgreSQL three-BEAM owner-replacement sequence passed with the intermediate
package, and the SIGKILL dispatch-intent sequence passed with the exact final
package above. Each preserved unknown without replay or fabricated Exit, kept
the stopped full receipt and blocked reservation until explicit resolution,
then verified deletion and released capacity. A third BEAM preserved the
tombstone and unchanged unknown history. The durable guide records each exact
package and process identity; these checks do not qualify the whole fault matrix.

Native checks passed 69 Rust tests and four Python integrity tests, formatting,
Clippy and Rustdoc in `.local/embedded-vm-native-check-final.log`. `mix ci`
passed 739 checks (4 doctests, 6 properties, 729 tests), 29 lab cases excluded,
including every analyzer and Dialyzer, in `.local/embedded-vm-ci-final.log`.
PostgreSQL passed 93 contract tests with 29 lab cases excluded in
`.local/embedded-store-postgres/vm-contracts.log`; ExDoc passed with warnings as
errors in `.local/embedded-vm-docs.log`. Container artifact admission and all
seven malformed-pack rejections passed against the final package in
`.local/embedded-vm-artifact-proof.log`, without creating VMs or changing inventory.

Public admission remains disabled. Remaining format/extraction-layout and
fault/interference boundaries, receipt-less intent-bound absence resolution,
Linux evidence, fresh package consumers and source/license/distribution/release
gates remain required. Ordinary live VM-mode topology is now qualified only for
the exact macOS build and fixtures recorded above.

## Fresh package-consumer milestone — October 10, 2026

The maintainer `package-consumer` command now accepts an explicit approved native
package, container fixture, enrolled domain and new evidence output. It extracts
the Hex archive into a new application, resolves only production dependencies,
compiles with warnings as errors and runs the existing HTTP consumer checks.
The native proof runs from copied, digested tooling against that extracted
library; it uses no workspace build products or Rust fixture-authoring tool.
`--without-rust` requires both `rustc` and `cargo` to be unavailable on PATH and
checks this again inside the consuming application and native proof. Rust remains
installed elsewhere on this development host; the qualification concerns
consumption with neither compiler executable available to these processes.

The native consumer passed on macOS arm64 with Elixir 1.20.4 / OTP 29.0.6 and
Elixir 1.18.4 / OTP 27.3.4.15. The latter pinned minimum production dependency
versions: Req 0.7.4, Mint 1.11.0, Mint WebSocket 1.0.6, Jason 1.4.0, Telemetry
1.3.0 and NimbleOptions 1.1.0. Both used Hex archive SHA-256
`38d01ab25337ec98c655066a5a13c288df9c3693a80e43a9882490495404d5b3`,
signed native package manifest SHA-256
`2f21216070495a40b89e6346d512b5a15ee974d62af97a0a6e7b620739e49f40`
and container fixture SHA-256
`0f4a26a548738c6ba359701ea23c5d2bbb93f0c1d95f6444df897bfa99e27aa2`.
The copied Elixir proof SHA-256 was
`c0e3cf9b2ed13c8755eafe1e3c27f23e43ae1fa5510c2b7edabacb66a02ab76a`;
the inventory/protocol tooling SHA-256 was
`fec2941cc0daff32201520b2afa3827168b6fb9dc2d99ed48df512ee4058eb84`.

Each observed Exit 7 with the applied CPU, environment, workdir and numeric user,
transferred 1,048,593 exact binary bytes, preserved them through retained
stop/start, graceful helper shutdown and an abruptly killed Port owner, and
observed deadline/cancellation without fabricated Exit. Missing package and
wrong manifest digest failed local launch preparation. A mismatched domain could
not become ready or admit a valid qualification request, with `not_dispatched`
evidence and unchanged inventory. The correctly enrolled domain then ran the
positive proof. Explicit owned deletion restored the empty inventory baseline.
Reports include exact dependency locks and package source digests; package source
must remain unchanged. Native asset approval and the prebuilt helper remain
separate from the Hex package.

Private evidence is in `.local/embedded-consumer-current-complete/` and
`.local/embedded-consumer-minimum-complete/`, including their `report.json`, native
intents/receipts/evidence, private native logs and maintainer run logs. A separate
current-toolchain HTTP-only consumer passed with the same Hex archive and no
native options or assets in its extracted package, in
`.local/embedded-consumer-http-only/`. Its report records native proof as not
requested and verifies that Rust executables were unavailable. No developer,
Ecto or PostgreSQL dependency leaked into any production consumer.
The exact Hex archive remains in
`.local/embedded-consumer-current-qualified/smolbox.tar`.

The CI tooling suite passed 31 tests in `.local/embedded-consumer-ci-tools-final.log`;
the package archive checks passed three tests in
`.local/embedded-consumer-package-tests.log`. `mix ci` passed 739 checks
(4 doctests, 6 properties, 729 tests), 29 lab cases excluded, with every analyzer
and Dialyzer passing in `.local/embedded-consumer-ci-final.log`. These proofs exercise the internal
Port bridge while public admission remains disabled. They do not qualify the
public setup workflow, compatible upgrades between distinct native builds,
coordinated codec adoption, Linux consumption or the remaining fault and
distribution gates. The engine, helper package, protocol and persistent schema
did not change in this milestone.

## Intent-bound absence engine milestone — October 11, 2026

The shared engine now has a wire-neutral `inspect_creation` query over the
original `CreateRequest`. It returns only `CreationPresence::Absent` or
`Unverified`, with typed failures; it cannot mint a receipt, material identity or
owned machine. Intent/resource/artifact metadata is validated before querying,
and the per-name engine gate excludes simultaneous local lifecycle work.
No pack is opened or prepared: an approved artifact removed after an uncertain
create does not prevent observation of the enrolled native domain.

The fourth separately pinned SDK patch adds `SmolvmDb::vm_absent_checked`.
It takes an IMMEDIATE SQLite transaction, tests for a VM row or any creation
reservation, and only when neither exists invokes the host material verifier.
It rolls back without writes. This prevents cooperating SQL writers from
reserving/inserting the name during that observation. Active and stale
reservations both remain unverified; the query never invokes the SDK's
reservation API that reaps stale entries. Presence is tested without parsing or
adopting a stored VM row, so copied labels or malformed row data cannot confer
authority. Missing/corrupt tables and database failures remain errors.

The host verifier rejects local tracked handles and registry PIDs, any material
at the hashed VM directory, and redirected/non-directory domain ancestors. A
dangling symlink or partial file is presence rather than absence. Missing cache
roots are inspected without materialization. Host errors preserve their typed
category through the SDK callback. The query checks the database device/inode
before and after observation so a replaced, redirected or missing file cannot
use a stale cached connection as absence evidence. Reopening an enrolled domain
with initialization disabled also requires an existing regular database file;
it cannot silently recreate the missing SDK database. Explicit initial enrollment
still creates it. The observation does not fence arbitrary
filesystem edits or actors that start afterward; explicit controller/worker
quiescence remains a required precondition for managed resolution.

Ten new deterministic checks exercise isolated real SQLite files: complete
absence with a missing artifact and no VM/cache creation; matching-label and
corrupt row refusal; active/stale reservation preservation; partial/dangling
material; redirected roots; local handles/lifecycle contention; invalid intent
and broken schema; and an external SQLite writer blocked during the material
check, then admitted after the read-only transaction releases its lock.
Additional checks cover replacement/redirection/removal of the cached database
path and refusal to recreate a missing enrolled database during reopen.
These tests launch no VM and alter no shared SDK account records.

The full native checks passed 79 Rust tests and four Python integrity tests,
formatting, Clippy and Rustdoc in `.local/embedded-absence-native-check-complete.log`;
the focused engine run passed 42 tests in
`.local/embedded-absence-engine-tests.log`. The base SDK revision/archive and
the first three patches are unchanged. Patch 0004 SHA-256 is
`917229db77dffba0e7c515ae8810c33bf0259e7243061be1a5abdfa6efe32df4`;
the updated source-pin JSON SHA-256 is
`7c4fa62665795f8477b4733972871ea4abf0d6635a3023eef6442c0d2dc0c53b`.
Bootstrap verified the complete patched tree. The research checkout remains
read-only, and no new native package or live platform evidence is claimed here.

The Port protocol and Elixir managed-resolution paths still reject receipt-less
resolution. They must now carry this query with exact approved intent binding,
streamless/result-specific validation, pinned epoch, frozen target, drained
requests, worker lease and guarded durable write, followed by live lost-reply
and fresh-BEAM qualification against a rebuilt package. Automatic recovery must
continue preserving unverified creations, and explicit absence resolution must
preserve unknown command outcomes. Public admission remains disabled; the
remaining platform, fault, upgrade, setup and distribution gates remain required.

## Intent-bound absence Port milestone — October 11, 2026

Protocol 1.3 now carries `inspect_creation` with the complete original approved
creation intent. The helper and Elixir owner validate the exact artifact catalog
and resource profile before dispatch. Its separate streamless `creation_presence`
terminal accepts only `absent` or `unverified`; it cannot return a receipt,
observation, command completion, file data or output stream. Exact 1.2 peers fail
approval. The shared engine remains independent of the bridge, preserving the
additive Rustler path and separate future Kubernetes backend.

Explicit `Machines.resolve(..., quiesced: true, disposition: :deleted)` can now
check a lost creation receipt. Resolution pins the original owner/epoch, freezes
local target dispatch, drains pending requests, claims the durable worker lease,
binds the query to the saved assignment and performs the existing guarded store
resolution. Verified absence releases accounting without creating, deleting or
adopting a native machine. Present material remains unknown and reserved even
with matching labels. Stopped resolution still requires a saved full receipt.
Automatic recovery, audits and cleanup preserve receipt-less reservations;
uncertain commands are not replayed and no Exit is inferred.

Deterministic tests cover receipt-less absence, present material, unsupported
stopped resolution, required quiescence, exact original intent, capacity release,
receipt-required lifecycle operations, stale epoch/catalog rejection before
dispatch and result-type/stream confusion. The complete native check passed 80
Rust tests and four Python integrity tests, formatting, Clippy and Rustdoc in
`.local/embedded-absence-protocol-native-check.log`. Final `mix ci` passed 742
cases (four doctests, six properties and 732 tests), all analyzers and Dialyzer
with zero errors in `.local/embedded-absence-ci-final.log`. The CI-tool suite
passed 31 cases in `.local/embedded-absence-ci-tools.log`. Ninety PostgreSQL store,
backend, machine, worker-control, expansion and volume checks passed in
`.local/embedded-store-postgres/absence-contracts.log`; the private cluster was
stopped afterward. ExDoc also compiled successfully. These store checks do not
qualify a live PostgreSQL lost-creation-reply fault.

The newly built and signed macOS arm64 package is
`.local/embedded-port-proof/release-package-absence/`. Its manifest SHA-256 is
`7066c758f9d4286bbf659c00a3bb23e822ee17848a06f9dd0de713f133a5b726`,
executable SHA-256
`374402cd4c996bd096f3ba6a0a27e53088f0000f91758ce66b120462a326f252`,
assets SHA-256
`a0e91c6eb85048604b1ab96241deb54d4b6edf47b6b5efea3cd6fb2f75719dbb`,
and source-pin JSON SHA-256
`7c4fa62665795f8477b4733972871ea4abf0d6635a3023eef6442c0d2dc0c53b`.
It includes SDK patch 0004 and protocol 1.3. Prior 1.2 package evidence remains
historical evidence for its recorded builds.

The real native container proof in `.local/embedded-absence-native-proof/`
returned absence before creation, rejected an unapproved query before engine
dispatch, returned unverified presence across helper epochs and confirmed absence
after full-receipt deletion. It also repeated actual resources, numeric guest
users, environment/workdir, 1,048,593-byte file transfer, retained storage after
helper EOF and deadline without Exit. The Elixir Port proof in
`.local/embedded-absence-beam-proof/` repeated these presence checks, including
queries during reconciliation and after graceful shutdown and abrupt owner loss,
with actual Exit 7 and binary file preservation. Both returned SDK inventory to
its empty baseline.

Fresh production consumers passed against this same native package on Elixir
1.20.4/OTP 29.0.6 and minimum Elixir 1.18.4/OTP 27.3.4.15, using PATHs without
`rustc` or `cargo`. They consumed the same Hex archive, SHA-256
`82f9442df53c20d3d4cf06dde974490b688486fb0fc73fb5b204420eae425d31`.
Reports and native evidence are in `.local/embedded-absence-consumer-current-final/`
and `.local/embedded-absence-consumer-minimum/`; both passed HTTP smoke checks,
package/domain rejection, presence checks, lifecycle, exec/file preservation and
owned deletion with unchanged inventory. Their proof-tool SHA-256 values are
`74658e4a4d873eb95c25d3345778eb850dce59b3226c285a664b6e6665e31e90`
for the Elixir proof and
`51f5fa7e6b77df2588e09199ebe42a7765cabd9de7bc5d58558023630f7e3193`
for the Python inventory tool. The consumer runner now creates a missing output
parent before launch so failures retain their private log. Rust remains installed
elsewhere on this development host; the qualification concerns its absence from
the consuming process PATH.

Public native admission remains disabled. Live lost-creation-reply/fresh-BEAM
PostgreSQL resolution, the broader fault/interference matrix, VM-pack regression
against this exact new package, Linux qualification, cross-build upgrade/draining,
public setup and distribution review remain required. This milestone does not
complete the first usable release or qualify arbitrary same-account filesystem
and database interference.

## October 11: durable persistence faults and protocol 1.3 VM regression

The encrypted PostgreSQL proof now supports five selected BEAM-loss checkpoints:
creation intent, creation reply, start reply, exec intent and exec result. The
SIGKILL runner kills only its owned BEAM and observes helper exit; recovery and
verification use distinct fresh processes. See the [durable proof](embedded-port-durable-proof.md)
for the precise checkpoint semantics, commands, private evidence directories and
recorded PIDs. All five sequences passed on macOS arm64 against the unchanged
protocol 1.3 package manifest
`7066c758f9d4286bbf659c00a3bb23e822ee17848a06f9dd0de713f133a5b726`
and approved fixture
`0f4a26a548738c6ba359701ea23c5d2bbb93f0c1d95f6444df897bfa99e27aa2`.
Each ended with zero reservation and empty baseline inventory.

Lost creation replies remained receipt-less and reserved while native material
existed, including after audit and explicit deleted resolution. Fixture maintenance
used the authentic out-of-band receipt for stopped deletion; it never inserted
that receipt into SQL. A later intent-bound absence query released accounting.
Lost start replies recovered stopped storage with the original full receipt and
reservation. Lost exec results remained unknown without fabricated Exit or adopted
output; after explicit stopped resolution, a separate command observed a persistent
counter of exactly one. Exec marker/counter fixtures use numeric root because the
workspace is root-owned. The dispatch-intent rerun has a writable marker; earlier
non-root marker assertions alone were insufficient evidence of no replay.
Failed fixture/checkpoint trials were explicitly disposed and excluded from passing
qualification. These cases do not qualify helper kills during live execution or
boot-time parent loss.

The final committed Elixir proof-tool SHA-256 is
`4df747a3c7aeab6e32bf65bd88eff1c04d86a6bed25103b1dbec18a13072b31e`;
the SIGKILL runner SHA-256 is
`27f6876aab08ed2685ae0312cdccc173c7d6fa10771d4a38a5f8df24e1025c8d`.
Tools evolved during qualification; these identify the final tools, not byte-for-byte
tool provenance for all earlier sequences. No Rust engine or packaged executable
changed in this milestone.

The real bare-VM regression also passed against this same package in
`.local/embedded-live-vm-pack-protocol13/result.json`. It preserved root and storage
snapshots, returned actual Exit 7, verified resources and root UID, rejected explicit
VM users, preserved a 3,341-byte file across stop/start and helper EOF, and deleted
both owned machines with unchanged inventory. Seed SHA-256 was
`73e3f63601cb5fdd4643ab0a24a913a79f1047fae8c76b18cd367339bbec06af`;
exported pack SHA-256 was
`cc40b62ef779b5bf49527b528d902b5240247689c69e682f41b5630ad7acdd8d`.
Fixture-authoring tool SHA-256 was
`86bb340bed62dbb61f7b32f42d7c09edd70f95b1cc83984de6e64785a1c645f5`.

Final `mix ci` passed 742 cases, all analyzers and Dialyzer with zero errors in
`.local/embedded-durable-boundaries-ci-final.log`. PostgreSQL passed 93 contract
tests with 29 runtime cases excluded in
`.local/embedded-store-postgres/creation-start-result-contracts.log`. The private
PostgreSQL cluster was stopped after the fault sequences. The existing native
checks remain evidence for the unchanged executable.

The authorized `ssh linux` host and disposable nested-KVM lab are available.
Read-only preflight confirmed the reviewed lab scripts, provisioned Elixir/OTP and
guest KVM access. Test mode has no outbound network or Rust toolchain, so locked
Cargo dependencies were vendored into private staging for offline preparation.
The owned test unit was stopped and verified inactive with MainPID zero. This is
environment preparation; no Linux native build or live embedded qualification is
claimed. Linux runtime assets still need provenance verification before staging.

Public native admission remains disabled. The broader live fault/interference
matrix, Linux qualification, cross-build upgrade/draining, public setup and
distribution review remain required before completing the first usable release.

## October 11: Linux native package and helper-loss qualification

The available authorized `ssh linux` lab now passed an offline Linux x86_64 build,
native execution/retention, selected helper-loss faults, bare-VM packs and a fresh
production package consumer. The [reviewed report](../evidence/embedded-port-linux.json)
records exact identities, inputs, tools and scope. Private evidence is in
`.local/embedded-linux-protocol13-qualification/`; the owned physical-host staging
directory is `/var/lib/smolbox-lab/staging/embedded-port-protocol13-20261011/`.
The disposable test unit was stopped, verified inactive with MainPID zero and
its owned overlay recovery completed. The physical host's worker and sealed
baseline were not changed.

The helper was compiled from commit
`0a8aee9d89f6fd1cfec43bb8d6f7cf94c049be99`, pinned SDK revision
`9f446ae00219148ca4a703914f44a8e2fab11655`, source JSON SHA-256
`7c4fa62665795f8477b4733972871ea4abf0d6635a3023eef6442c0d2dc0c53b`
and four verified patches. The guest ran Linux 6.8.0-139-generic x86_64, glibc 2.39,
Rust 1.98.1, Python 3.12.3 and GCC 13.3.0. Cargo used locked vendored dependencies,
offline mode and two build workers. The new package manifest SHA-256 is
`a3839804811d911d495eb6db42d79d3e8bd705561c02408974d28205bf15205b`,
executable SHA-256
`a0d0996db1af009c434cc3e40980f6ab112f1835af387df80c96365c57a2af6a`,
and assets SHA-256
`13628c666d71d23346ef3685a25ac63535cfa77391dab6604fa66c1eef708ec8`.
It implements protocol 1.3. Existing macOS evidence retains its separate identities.

A fresh download from the official 1.22.0 Linux release URL matched archive
SHA-256 `00d2f057c963ff950846d4059af87bdddb7edf707750cdab863cb0879d6b339e`.
This differs from the earlier fixture record; that historical pin was not silently
reused or replaced. The new URL/digest and exported assets are recorded for this
qualification. Binary/source and license correspondence still require distribution
review. A clean Cargo vendor archive avoided macOS AppleDouble metadata files,
which had caused a C dependency to compile an unintended `._*.c` file.

The fixture-authoring example now writes a prepared artifact directly with
`pack_artifact`, rather than generating a launcher and deriving the sidecar path
incorrectly for an already suffixed output. The helper/engine library did not
change. The rebuilt fixture tool SHA-256 is
`d469be46a18edd40c1e9190ded7dca473a0dea03f7b13c32515fbdf04c047d9b`;
its approved container fixture SHA-256 is
`8ac12958bc166344f1ffeb4c518c883c750fece358bf177f13f6ded7953cfe5b`.
The tool changes and proof scripts are recorded separately from the helper's
build commit in the reviewed report.

The native proof passed actual CPU/disk configuration, numeric guest users,
environment/workdir, 1,048,593-byte byte-exact file transfer, retained data across
helper EOF, a deadline without Exit, intent-bound absence checks and owned deletion.
Linux kernel usable-memory totals differed from the macOS-derived assertion:
512 and 768 MiB requests reported 525,000 and 783,048 KiB. The proof now records
these values and independently checks allocation scaling, with the narrow
allowances documented in `native/README.md`. It does not infer a host quota from
kernel memory counters. Failed fixture/resource trials were disposed through
authentic receipts and excluded from passing qualification.

The new lab-only `fault_proof.py` passed helper SIGKILL while idle, before command
send, after acceptance and after an actual stdout witness during exec. Every case
verified the original VMM PID/start identity exited, restored a fresh helper epoch,
observed retained stopped storage and used explicit full-receipt deletion to restore
the empty inventory. The synced command counter was zero before send/at the
observed acceptance trial and one during exec. This is raw protocol/native
qualification; no durable-store reservation or command-history claim is made.
An initial unsynced counter was lost on crash; that fixture was explicitly disposed
and the passing checkpoint includes guest `sync` before its stdout witness.

The bare-VM proof passed actual Exit 7, root/storage snapshot preservation, neutral
startup, resource/user checks, retained file data across helper EOF and owned
deletion. The seed and exported pack SHA-256 values are in the reviewed report.
A direct Elixir Port proof and a fresh production consumer both passed against
this same package with no Rust executable in their PATH. The consumer used the
same Hex archive as the macOS consumers, SHA-256
`82f9442df53c20d3d4cf06dde974490b688486fb0fc73fb5b204420eae425d31`,
Elixir 1.20.4/OTP 29.0.6 and an independently prepared public Hex cache in offline
mode. It passed HTTP smoke checks and native package/domain rejection, real Exit 7,
file retention, fresh-epoch recovery and verified cleanup. Rust existed elsewhere
in the guest filesystem; the claim concerns absence from consuming-process PATH.

Linux passed all 80 Rust tests and four Python source-integrity tests, formatting,
Clippy for all targets with warnings denied, Rustdoc with warnings denied and
production Elixir compilation with warnings as errors. Logs and immutable package
exports were saved before teardown. No first usable release is claimed yet.

Source review identified a remaining boot-time parent-watch race: the SDK manager
passes only a watch flag, while `internal_boot::run` captures `getppid()` after the
child has started. If the owner dies before that capture, the watcher could bind
to the adopted parent. This is an inference from the pinned source, not a passing
or reproduced runtime fault. The next boot-loss qualification must exercise this
window and fix parent identity transfer and watcher startup failure handling.
Current idle/accepted/running tests do not cover it.

Public admission remains disabled. Boot-time parent loss, live caller cancellation
and sibling isolation, the broader exhaustion/interference matrix, Linux durable
faults and minimum-toolchain consumption, compatible upgrades/draining, public
setup and distribution review remain required.

## October 11: boot-lifetime fix, awaiting rebuilt-package qualification

The disposable Linux lab reproduced two boot-lifetime faults in the previously
qualified four-patch package (manifest SHA-256
`a3839804811d911d495eb6db42d79d3e8bd705561c02408974d28205bf15205b`).
Pausing the actual `_boot-vm` child before Rust main, killing its original helper
and resuming the child let boot initialization proceed under an adopted parent.
Independently, injecting failure of the first watcher-thread creation let boot
initialization proceed without the watch. Both original children remained alive
beyond six polling intervals. The proof killed/reaped only its pidfd-bound owned
child, then used its authentic receipt for verified stopped deletion. Both cases
reported restored empty inventory. These are reproduced diagnosis observations,
not successful regressions against the fix.

The lab subsequently reached its 45-minute service deadline. Read-only status
confirmed MainPID zero, and the owned overlay recovery completed. The per-case
guest reports were not exported before teardown; the observed results remain in
the tool transcript. Repeat qualification must export the evidence before stopping
the lab. No live test process remains, and no production worker was changed.

The separately pinned `0005-owner-bound-boot-watch.patch` now transfers the
manager's own PID before spawning. A watching boot child refuses missing/invalid
owner identity before reading configuration, checks for prior owner loss
synchronously, and propagates watcher-thread creation failure. Detached launches
remove the inherited PID variable. The existing void watcher API remains available
and fails closed if arming fails. SDK patch SHA-256 is
`ce5241e2a2b9ae494e894b2693991ca7bf06c01afd029bf2c708b0563191fbf1`;
the new source JSON SHA-256 is
`e303886b242f160006bf6da73735e52f2276fe48b2a5f68b686f4ebc3df1e70b`.
The research checkout was not edited.

New isolated Rust subprocess contracts cover missing/malformed owner PIDs,
already-lost parents, normal arming and the disabled-watch path. The Linux-only
boot proof and its injected C shim remain explicit lab tools; they are not shipped
with the helper or run by ordinary Cargo tests. `native/check.sh` passed on macOS
with 83 Rust tests (including three new contracts), four Python source-integrity
tests, workspace formatting, Clippy for all targets with warnings denied and
Rustdoc with warnings denied. Python proof syntax checks also passed. The check
used private copies of the approved libraries; its log is
`.local/embedded-boot-parent-qualification/native-check-macos.log`.
No rebuilt release package or live regression against this fix is qualified yet.
Historical Linux/macOS evidence applies only to its recorded four-patch packages.

Remaining first-release work:

- Build new five-patch Linux/macOS packages, run the boot regressions and ordinary
  native/package-consumer regressions, and export exact identities/evidence.
- Finish live caller cancellation and sibling isolation, output/backpressure/file
  budget checks, database/interference and scoped-reaping fault coverage.
- Qualify Linux durable-store faults and the minimum-toolchain Linux consumer.
- Exercise compatible upgrades, draining and coordinated codec adoption.
- Complete public setup examples and build/signing/digest/source/license delivery
  review, then enable public native admission only after the required gates pass.
- Run final relevant analyzers, contracts and HTTP regression checks against the
  completed implementation. Rustler and Kubernetes remain future additive work.

## User-directed qualification scope

The user requested continuing without the deliberate interruption tests after
repeated client safety notices. Live helper/BEAM interruption, boot pausing and
watcher-failure injection are deferred. Continue normal native package builds,
execution, file transfer, retained stop/start, graceful stopped-helper reopening
and verified deletion. The new `ordinary_proof.py` records that narrower scope
and explicitly leaves crash handling unqualified. No cause for the client notice
has been established. The remaining release gates stay visible; ordinary checks
must not be presented as complete failure qualification.

## Ordinary validation of the five-patch packages

Both rebuilt packages passed the separate ordinary lifecycle proof using helper
source from `d82a2db` and source JSON SHA-256
`e303886b242f160006bf6da73735e52f2276fe48b2a5f68b686f4ebc3df1e70b`.
The [paired report](../evidence/embedded-port-ordinary.json) records each platform's
exact package/build/asset identity and the separate proof-tool digest. macOS
manifest SHA-256 is
`687315ca3de50fdce4670fb40bedd361bbe9914ebe64b8437b2d048abc3f04bf`;
Linux manifest SHA-256 is
`0c4bab19131e04a2cace3438dfb78191705674465bfead2aa9f90f37975a76fa`.
The macOS package has a verified ad-hoc signature and hypervisor entitlement;
this is not Developer ID/notarization or distribution approval.

Each platform returned actual Exit 7 and verified one guest CPU, both 1 GiB disks,
environment/workdir and numeric non-root UID 65534. A 1,048,593-byte binary file
matched exactly before and after stop/start, and after a normal helper shutdown
with the VM already stopped and reopening under a fresh helper epoch. Full-receipt
deletion restored each empty baseline inventory. No deliberate helper/BEAM
interruption, boot pause or watcher-failure injection ran in this milestone.
The report explicitly marks crash handling unqualified.

The Linux build used the locked offline vendor/toolchain inputs and a disposable
lab overlay. Package and private evidence exports were verified and saved before
the lab stopped, with MainPID zero. Private local evidence is in
`.local/embedded-ordinary-five-patch/`; the existing physical-host staging directory
holds the exported Linux package and reports. The source-only archive came from
the committed helper source; the ordinary proof was staged separately and hashed.
The research checkout and production worker were not changed. Public admission
and the remaining first-release gates remain pending.

## Ordinary production consumer mode

The maintainer consumer now accepts `--native-ordinary` with its complete native
package options. It stops the VM before graceful shutdown, observes retained
storage under a fresh Port epoch, restarts explicitly, verifies byte-exact data
and deletes through the original receipt. The existing explicit fault mode
remains available. Evidence and consumer scope distinguish the modes and never
declare full crash handling qualified.

Fresh macOS production consumers passed against the five-patch package under
Elixir 1.20.4/OTP 29.0.6 and Elixir 1.18.4/OTP 27.3.4.15. Both consumed the same
new Hex archive, checked HTTP smoke behavior, real Exit 7, binary retained data,
missing/wrong package and domain rejection, fresh-epoch recovery and restored
empty inventory, with `rustc` and `cargo` absent from both process PATHs. The
minimum lane resolved the six declared minimum dependencies exactly. Private
reports/logs are under `.local/embedded-consumer-five-patch/`; proof-tool hashes
and exact archive/package identities are in each report. The standalone CI
tooling suite passed 31 cases. These results cover ordinary consumer integration,
not Linux consumption, upgrades, fault completion or public admission.

## Finite qualification, package consumers and release review

The [qualification report](../evidence/embedded-port-qualification.json) records
the exact manifests, helper/asset identities, tool hashes, private export hashes
and scope of this campaign. Public native admission remains disabled. Live
helper/BEAM interruption, pre-main boot/watch-failure injection and associated
durable crash boundaries remain deferred at the user's request.

Linux passed witnessed foreground cancellation with no fabricated Exit, sibling
execution during and after cancellation, finite output and file limits, cancelled
partial upload preserving existing bytes, slow-consumer credit bounded to
262,144 bytes, and epoch-fenced quiescence/reactivation. The cancellation proof
does not claim guest termination. The original stopped VM and sibling were
deleted through authentic receipts, restoring the empty inventory.

Record interference checks rejected changed CPU material despite copied labels,
corrupt rows, a held SQLite write transaction and stale receipts after same-name
recreation. A separate unpatched SDK CLI also changed the proof's stopped VM CPU
setting while the helper was active: native inspection/deletion rejected that
material and preserved the row. Restoring the setting through the CLI allowed
authentic cleanup. This finite case does not qualify destructive concurrent CLI
races. Failed harness assertions were retained privately and excluded from passing
evidence; cleanup used the known fixture's authentic receipt.

Linux native checks passed 84 Rust tests, four Python source-integrity tests,
formatting, Clippy and Rustdoc. The new reaping contract ran 32 rounds of normal
pipe-released subprocess exit, proving registered-child collection without
stealing an unrelated sibling's wait status. Live helper child lists across all
threads became empty after three normal VM stops. These checks introduce no live
process-loss faults. A required native CI lane now runs the contract suite; the
hosted workflow itself has not yet run.

Linux PostgreSQL store contracts passed 93 tests with 29 live-runtime cases
excluded. These cover SQL/store faults and codec recovery contracts, not the
deferred live BEAM crash boundaries. Focused native codec/recovery, Port and worker
draining contracts passed 44 tests. The four-patch to five-patch retained-machine
upgrade passed on Linux and macOS with original receipts/generation, byte-exact
data and empty final inventories. Only those package pairs are qualified; their
proof-script digest was not captured at execution. Firmware migration and codec
rollback remain unqualified.

The builder now includes SmolBox/SDK license texts, upstream component summary and
native source metadata in the hashed asset inventory. Both rebuilt packages
passed ordinary execution and retained-data checks. Every copied license/source
file was individually changed in private package clones: both platforms returned
framed package-preflight rejection with empty capabilities before engine startup,
preserving the original files and inventory.

Fresh production consumers of the setup-guide Hex archive passed with Rust absent
from PATH on Linux and macOS, both Elixir 1.20.4/OTP 29.0.6 and minimum Elixir
1.18.4/OTP 27.3.4.15. The minimum dependency versions resolved exactly. Both lanes
checked ordinary native lifecycle/recovery and HTTP smoke behavior against the
rebuilt metadata package; a separate HTTP-only consumer required no native package.
The archive predates this final evidence/README update; library source is unchanged.
Private Hex/Rebar/toolchain caches were used on Linux without copying credentials.

Final live HTTP regression passed three selected SDK 1.22.0 tests covering direct
Python binary files/nonzero Exit, startup/file initialization without replay, and
managed Python/JavaScript binary collection and cleanup. Inventory returned empty
and the server stopped normally. The first trial failed two cases after a cold
boot exceeded its 15-second receive window and left a late fixture; that trial is
excluded. Its evidence was exported and its owned lab overlay shut down. The
passing run used a fresh overlay and explicit cold setup allowance, preserving
individual command/cancellation deadline overrides.

Full Elixir CI passed 742 tests (29 runtime exclusions), analyzers and Dialyzer;
standalone CI tooling passed 31 tests. Documentation built without warnings and
the new configuration example validated the approved macOS package without
starting a helper. The Linux private evidence/package exports were verified before
the lab stopped with MainPID zero. Production workers, sealed baseline and research
checkout were unchanged.

The [public setup guide](../embedded-port.md) covers separate package installation,
ownership, capability/budget limits, retained state and upgrade/draining procedure.
Its example validates configuration only; it does not bypass Runtime admission.
The [distribution review](../../native/release-review.md) records unresolved exact
firmware/kernel source correspondence, source/license delivery and publisher
signing. The explicit macOS signing-identity builder path still needs a real
distribution signer, notarization as applicable and consumers of the signed bytes.

Remaining release gates are the deferred live interruption/durable crash cases,
destructive concurrent CLI races and broader resource exhaustion, complete native
source/license delivery and signing, and a public managed embedded startup/draining
and mixed HTTP/Port live campaign. The first usable public Port release is not yet
complete. Rustler and Kubernetes remain future additive implementations.


## Public development Runtime completion — October 11, 2026

Public Runtime admission now accepts one explicitly approved embedded Port target
per BEAM node alongside HTTP targets. Startup validates the store's backend binding,
recovery and managed-machine capabilities before launching the helper. Existing
supervised enrollment, authenticated reconciliation and package/domain/Hello checks
remain mandatory. This completes the ordinary development scope authorized by the
user; it does not claim completion of the deferred live interruption campaign or
native distribution approval. Rustler remains an additive future bridge, and
Kubernetes remains a separate future backend.

The public example uses `SmolBox` supervision and public execution, machine and
worker-control APIs. It checks disposable Exit 7, retained lifecycle, 1,048,593
binary bytes, new-work expiry during draining, retained commands while draining,
normal Runtime shutdown/restart with the store alive, persisted drain state,
versioned resume, and final owned deletion with zero reservations. It records
private codec-encoded authority before shutdown, including failures. These files
are forensic evidence, not a durable store backup or restore interface. The
Memory example explicitly warns that whole-store/BEAM loss can strand VMs.

Fresh production consumers passed on Linux x86_64 and macOS arm64 under both
Elixir 1.20.4/OTP 29.0.6 and minimum Elixir 1.18.4/OTP 27.3.4.15, with Rust tools
absent from PATH. All four use `--native-public`, the same archive and identical
example/configuration/proof tool bytes. Their library and `mix.exs` digests match
the final implementation. The approved helper packages are unchanged from the
previous native qualification. Linux first enrollment was exercised through
public startup, with explicit initialization followed by ordinary initialization
disabled. A separate PostgreSQL-backed public flow passed with an isolated HTTP
SDK domain: HTTP execution succeeded while the embedded target remained drained.
Both native and HTTP inventories were empty after owned cleanup.

Two failed live attempts are retained and excluded from passes. The first exposed
input admission reading output `max_bytes` instead of input `size`; the corrected
validation has a public binary-transfer regression. That stopped fixture from the
isolated trial was removed by operator CLI after checking its exact immutable row
digest, without inventing a receipt. The second exposed an example lifecycle
version race; only explicit `stale_version`/`not_dispatched` conflicts now receive
bounded refreshed retries. Its original codec-preserved receipt authorized normal
helper stop/delete before rerun. Unknown outcomes are never replayed.

Final validation passed 746 Elixir checks with 29 live tests excluded, all ordinary
CI quality/static checks including Dialyzer, 32 standalone CI-tool tests, an example-
inclusive clone check and documentation with warnings treated as errors. Three
selected real Linux HTTP regressions passed on the final library bytes: low-level
Python/file/Exit, command initialization without replay, and managed Python/
JavaScript binary collection and cleanup. Their isolated SDK inventory was empty
and the server stopped normally. The disposable Linux lab is stopped (MainPID 0).
No live helper/BEAM kills, pre-main boot pauses or watcher-failure injection were
run in this campaign. The research checkout and production worker were unchanged.

Safe identities, input/source digests, results, failed trials and limits are in
[the public Runtime evidence](../evidence/embedded-port-public-runtime.json).
Historical gate statements and evidence above describe their recorded milestones;
they do not describe current public development availability. Remaining release
work is live crash-boundary and independent CLI-race qualification, exact binary/
source and license delivery, and publisher signing/provenance with consumers
against the resulting signed bytes. No native package was published.

## October 11: interruption campaign stopped at the user's request

The user reauthorized the deferred interruption campaign, then requested that it
stop after another client content notice. No cause for that notice has been
established. No further crash or CLI-race validation is authorized by this
milestone. The independent CLI-race harness remains an unrun private draft.

Before that request, the five-patch Linux package passed both pre-main boot cases
(parent loss and watcher-thread creation failure) and four helper-loss boundaries
(idle, before send, accepted and running). A harness reaping assertion was fixed:
the watcher-failure child can already have been reaped by the helper, so ECHILD is
accepted only for that case after the original child birth identity is absent.
Both boot cases passed after authenticated fixture cleanup and rerun.

All five macOS public PostgreSQL Runtime boundaries completed prepare, recovery
and third-process verification: exec intent, exec result, create intent, create
receipt and start receipt. Each ended with zero reserved slots and owned deletion.
Linux exec-intent recovery completed, but third-process verification failed the
exact historical completed-record equality assertion; this is an unresolved
verification failure, not a qualified Linux durable sequence. The remaining Linux
durable boundaries and independent CLI races were not run.

The durable harness now starts through public `Runtime.start_link/1`, and its
runner disconnects stdin. Private receipts, keys, database files and logs were
preserved under `.local/embedded-crash-qualification`; no receipt-bearing evidence
was published. Both SDK inventories were empty, both owned PostgreSQL clusters
were stopped normally, and the disposable Linux lab was stopped with MainPID 0.
The research checkout and production worker were unchanged.

Public development admission remains available. Outside the deferred validation,
distribution work still requires exact native binary/source correspondence and
license delivery, publisher signing/provenance, and consumers of the final signed
bytes. Rustler and Kubernetes remain future backends.

## October 12 Design for removing downstream SDK patches

The [unmodified SDK design](embedded-port-unmodified-sdk.md) and
[implementation plan](embedded-port-unmodified-sdk-implementation-plan.md) replace
the downstream patch strategy with SmolBox-owned transfer workers, approved asset
preparation, exclusive-domain lifecycle policy, read-only creation observation and
an owner guard in the boot launcher. They preserve the embedded Port backend and
the shared-engine boundary for future Rustler support.

The migration starts from the current clean upstream revision; a newer SDK upgrade
is separate. Independent concurrent SDK writers remain unsupported, and atomic
receipt checks inside upstream lifecycle locks are not promised after removing
that patch. Rustler must not mutate BEAM's process-wide environment. Crash and
destructive CLI-race validation remain deferred. This milestone adds documents
only; no dependency source, native package, store codec or runtime code changed.

## October 12, 2026: clean SDK input and API audit

Added a separate schema-2 clean source manifest and complete content/mode
inventory for the existing upstream pin. All 290 exported files matched upstream
Git blobs and executable modes. Bootstrap clean mode verifies the full inventory
and preserves the active patched cache. Six bootstrap integrity tests passed.

The compile-only public API fixture passed offline on macOS arm64 using private
libkrun copies, without SDK runtime initialization or VM launch. The
[native boundary audit](../../native/clean-sdk-api-boundaries.md) records API uses,
exact upload-size enforcement and remaining template/launcher feasibility gates.
This is migration progress, not a clean package release. Runtime replacements,
build switching and ordinary package qualification remain pending. Crash and
destructive CLI-race validation remain deferred.

## October 12, 2026: shared owner context and launcher primitive

Added transport-independent host owner/executable context and an immutable
epoch-specific boot launcher primitive in the shared Rust engine. Its source
performs the synchronous parent birth check and arms the SmolBox watcher before
SDK initialization; helper activation remains pending. Contexts are retained
until engine integration can prove child collection.

All 49 engine library tests passed, including five new non-VM host contracts. A
copied macOS test executable exited normally in listing mode and passed strict
code-signature verification. Engine clippy passed with warnings denied in SmolBox
code; upstream deprecation warnings remain unchanged. Clean and active source
inventory checks passed. The native check script now explicitly selects ordinary
tests and normal child reaping, excluding the historical parent-loss campaign.
No live owner-loss, watcher-failure, crash or destructive CLI-race tests ran.

## October 12, 2026: bounded file workers using public SDK APIs

The shared engine now stages exact upload inputs, admits bounded workers and
spools, supervises private correlated IPC, and retains domain/machine/source
leases through exact child collection and read forwarding. The Port supplies
verified host context. SDK socket cloning and timeout construction are no longer
used. Revision-specific nonblocking source-lock admission is isolated from bridges.

Ordinary macOS checks passed: 57 engine tests, 14 Port tests, six protocol tests,
six source-integrity tests and all-target lint. Two explicit real-helper non-VM
fixtures also passed, including binary streaming through public SDK agent APIs,
normal exit and retained source leases. `native/check.sh` selects these ordinary
fixtures explicitly; historical fault integrations remain excluded. No live
owner-loss, persistence interruption or destructive CLI-race checks ran.

This is an intermediate implementation milestone. Asset resolution, lifecycle
and absence replacements, boot activation, clean build switching, public status
propagation, Linux checks and ordinary VM/package consumers remain pending. The
existing approved development packages and historical crash evidence are unchanged.

## October 12, 2026: approved account templates without resolver hooks

The engine prepares and records approved account templates under its domain lock;
the Port supplies descriptors from the verified package manifest. All selectable
home/helper/boot-directory candidates must match approvals. Plain/compressed bytes
and ext4 geometry are checked, files publish without overwrite, and changed asset
identity blocks activation. Account assets and package references are retained.
APFS installation punches verified zero blocks in private staging; sparse bytes,
logical geometry and restart inode preservation passed the normal fixtures.

Package authoring now regenerates compressed templates after shrinking plain
copies, avoiding the old builder's inconsistent compressed geometry. Existing
approved packages are untouched. Three resolver tests passed against verified
unmodified SDK source, covering actual lookup order, missing assets, compressed
expansion and normal restart reuse. Five engine asset contracts cover sparse
installation, conflict preservation, references, redirection and geometry.

This milestone removes use of the template override for new helper operation,
but the active build still retains SDK patches until lifecycle/absence and boot
integration are ready. Linux, ordinary VM/package consumers, clean build switching
and final public metadata remain pending. Crash validation stays deferred.

## October 12, 2026: cooperating lifecycle and read-only SDK observation

Removed patched lifecycle/absence API calls from engine and bridge source. The
engine checks receipt, incarnation, material, dependents, state and PID identity
under its shared gate before ordinary SDK mutation. Precondition rejection remains
not dispatched; SDK-entry errors remain uncertain. Source-flock self-contention
is covered by a deterministic fixture. Independent concurrent SDK writers remain
unsupported; old atomic-callback tests are historical evidence only.

Adapter version 1 validates the clean baseline's schema and reads existing VM/
reservation rows in a consistent read-only SQLite snapshot. It preserves stale
reservations and corrupt-row presence, rejects unsupported/missing/replaced/
redirected/busy databases, and checks host material without creating paths.
Existing databases are validated before SDK initialization can repair schema.
Domain binding and live lock/directory identities are rechecked as well.

Temporary-DB and modeled lifecycle contracts exercise these behaviors without
VMs, owner loss, live persistence interruption or external CLI races. Boot
activation/epoch fencing, public availability, clean-source build switching and
ordinary platform/store/consumer qualification remain pending. Historical crash
results, including the unresolved Linux verification failure, are unchanged.

`native/check.sh` passed on macOS arm64 after this milestone: 69 engine, 13 Port
and six protocol tests, plus the two explicitly selected ordinary worker fixtures;
seven Python checks and three separately selected clean-resolver checks; format,
lint, Rust documentation and both source inventories. The Linux-only child-reaping
integration had zero macOS cases. No live VM or deferred fault qualification ran.

## October 12, 2026: SmolBox boot guard and persistent epoch fencing

The Port prepares an immutable approved launcher/context before its worker threads
and readiness. `_boot-vm` checks its own context, domain-local config and the
pre-spawn owner's PID/birth/UID, then waits for watcher readiness before SDK entry.
The shared engine records pending boot attempts and exact enrolled boot/transfer
children. Missing or contradictory boot enrollment retains uncertainty. Admission
failures before SDK entry retain `NotDispatched`; SDK-entry errors are uncertain.

Prior epochs must be authenticated and quiescent before a replacement engine can
open the SDK. Normal shutdown seals only a collected epoch. Unknown attempts,
children, entries or modified context block replacement without deleting evidence
or rotating the domain generation. Creation absence checks related actor evidence;
running siblings do not prevent absence for another intent. Transfer status remains
owned by its supervisor; boot collection is per exact enrolled PID/birth.

All 73 engine unit tests passed on macOS arm64. Four new non-VM contracts cover
unresolved dispatch, normal sealing/retirement, sibling/status isolation and boot
enrollment retention. A real copied-helper guard fixture also passed: invalid SDK
configuration exits normally after guarded enrollment, without launching a VM.
Clean SDK source review confirms the watcher needs no inherited FD and uses
permitted sandbox syscalls. No live owner-loss, injected watcher failure,
persistence interruption or destructive CLI-race tests ran.

The workspace build still uses the historical patched SDK until the clean-source
switch; existing approved packages and evidence remain unchanged. Linux and actual
VM/package qualification, public availability propagation, clean package metadata,
consumer/toolchain/store regressions and final documentation remain pending.

The complete ordinary `native/check.sh` also passed after this milestone: 73
engine, 13 Port and six protocol unit tests; two selected worker fixtures and one
selected guard fixture; seven Python checks and three clean-resolver checks;
format, lint, Rust documentation and both source inventories. Linux child-reaping
had zero macOS cases. The guard fixture and actual VM qualification are distinct.

## October 12, 2026: active build switched to unmodified SDK input

The normal workspace now uses schema-2 `native/vendor/source.json` and its
authenticated 290-file upstream content/executable-mode inventory. Bootstrap
contains no patch application and rejects any nonempty patch list, Cargo
patch/replace overrides, substituted workspace dependencies or direct SDK fork
dependencies in native member manifests. The independent API/resolver cache uses
the same clean source inputs. All five active downstream patch files are removed.

Patch-specific parent-watch and boot fault fixtures are removed from the active
tree and preserved in Git at `4be5e7b`; they depend on hooks absent from clean SDK
source. This does not complete or resume crash validation. Historical patched
package evidence and approvals are untouched. The public migration guide requires
draining/deletion through original authority and fresh enrollment, without
automatic receipt adoption or generation reset.

The ordinary native check script passed on macOS arm64 against the active clean
SDK: 73 engine, 13 Port and six protocol unit tests, two worker fixtures, one guard
fixture, format/lint/Rust documentation, and both complete source inventories.
Eight Python checks passed after the final Cargo bypass verifier addition; three
actual clean-resolver checks passed in the full native run. Upstream deprecation
warnings remain unchanged. No VM or deferred fault campaign ran.

The ordinary Elixir suite also passed with warnings treated as errors: 746
passes (four doctests, six properties and 736 tests), 29 runtime cases excluded.
It uses simulated native bridge/store fixtures and ordinary fresh-process codec
decoding; it does not qualify real native package crashes or live store interruption.

This is the source-switch part of phase 6, not completion of that phase or the
goal. Explicit package policy/observation metadata, public availability
propagation, new Linux/macOS packages and ordinary VM/toolchain/store/upgrade/
draining/HTTP consumer evidence remain pending. Publication and crash gates are
still separate, and the historical Linux durable verification failure remains
unresolved.

## October 12, 2026: explicit ordinary consumer selection

The native package-consumer entry point now requires `--native-public` or
`--native-ordinary`; native options without either mode are rejected before native
work. The internal Elixir proof requires `--ordinary` before tool setup or package
access. This removes its former implicit interruption-mode default. HTTP-only
consumer selection remains unchanged. Five package CI contracts passed, including
the new rejection contract; a direct no-mode proof invocation also returned the
expected error before package/domain access. Formatting checks passed.

Crash qualification remains deferred. The remaining native runner cleanup/timeout
fallbacks still need an audit before ordinary live package validation; these mode
checks do not qualify or authorize those fallbacks.


## October 12, 2026: ordinary runner failure preserves unresolved work

The common Python Port runner now uses EOF and bounded waiting on startup or
proof failure. Forced-kill fallbacks are removed. An unresolved wait records a
private diagnostic PID without treating it as authority, leaves crash
qualification false and preserves existing intent/receipt/epoch evidence. Loader
injection/override variables are cleared. Ordinary upgrade checks reject
patched-to-clean receipt adoption and incompatible clean policies before opening
a helper. Four modeled runner contracts passed; none starts or interrupts a VM.

This closes the forced-kill fallback in the common Python ordinary path. Separate
explicit fault scripts remain deferred and were not invoked. Production bridge
failure behavior is distinct from intentional fault validation.

## October 12, 2026: verified clean package policy metadata

New packages use manifest schema 2, with exact compiled policy metadata in the
manifest and hashed `SMOLBOX-POLICY.json`. Hashed `NATIVE-SOURCE.json` must match
the compiled source manifest, and license/source/policy files are required assets.
Policy version 1 records exclusive cooperating domain ownership, SDK observation
schema 1 and versions of SmolBox's workers, guard and asset preparation. Rustler
remains disabled. Config's approved manifest digest binds the policy; receipt
fields, codec v16 and Hello 1.3 remain unchanged at this checkpoint. Legacy
manifest approval cannot approve new clean bytes.

The complete ordinary macOS native check passed: 73 engine, 14 Port and six
protocol tests; two selected worker fixtures and one selected guard fixture;
format/lint/Rust documentation and both clean inventories. Thirteen Python checks
passed after the last upgrade/loader contract changes; three actual clean resolver
checks passed in the complete native run. Policy rejection covers legacy/missing/
changed/extended metadata, and the package inventory binds the policy file hash.
No VM or deferred fault campaign ran. New package builds, public availability
propagation and ordinary Linux/macOS VM/store/toolchain/consumer qualification
remain pending. No distribution approval or full crash qualification is claimed.


## October 12, 2026: native CI wrapper retains unresolved consumers

Native consumer execution now selects the CI child's no-signal retention mode.
Deadline/output overflow fails qualification and retains the bounded collector;
normal leader collection never triggers a process-group signal in this mode.
The detached collector retires after actual normal child collection. Private
retained-runner diagnostics include no deletion authority, and existing retained
reports cannot be reused. Generic non-native CI command behavior is unchanged.

Three ordinary shell/pipe contracts passed for deadline retention, bounded output
and detached execution followed by normal release/collection. Five package CI
contracts and formatting checks passed. No native helper/BEAM loss or signal
campaign ran; historical fault cases in the child suite were excluded. This
addresses the outer wrapper fallback as well as the shared Python fallback.
Production crash behavior and its deferred qualification remain distinct. Public
availability propagation and fresh clean package/platform/consumer qualification
are still pending; the goal is not complete.

Strict Credo passed across 483 Elixir source files after the wrapper changes.
Source inventory and changed-file formatting checks remained clean.

## October 12, 2026: engine availability reaches public admission

The clean helper now uses protocol 1.4 and manifest-bound policy metadata for an
epoch-only unavailable notice and a three-second native cancellation grace.
Unresolved native actors or transfer collection close admission while the live
helper, collectors, streams, credits and reserved capacity remain owned. The
notice carries no result or cleanup authority, is monotonic within its epoch,
and cannot trigger replacement. Queued operations are rejected before SDK entry.
The Elixir bridge requires at least four seconds of cancellation grace, covering
the transfer supervisor's 2.2-second collection interval. Native shutdown failures
are propagated rather than reported as a successful helper exit.

The bridge retains support for explicitly approved legacy schema 1 / Hello 1.3
packages with their original exact limits. A bounded read of approved manifest
bytes selects the required Hello version; unsupported or missing clean policy
cannot launch, and a legacy Hello cannot satisfy a clean manifest. Public health
reports the negotiated version and corresponding limits. The standalone native
CI retention diagnostics use the existing dependency-free JSON encoder; a broader
suite exposed and verified correction of an unintended Jason dependency.

The complete ordinary macOS native check passed: 73 engine, 17 helper and seven
protocol tests, two selected non-VM transfer fixtures, one selected non-VM boot
guard fixture, 13 Python contracts plus three real clean-resolver checks, format,
Clippy, Rustdoc and both complete clean source inventories. The Linux-only child
reaping contract was not exercised on macOS. The final ordinary Elixir suite
passed 754 cases (four doctests, six properties, 744 tests), with 29 live-runtime
cases excluded. Targeted public availability/manifest/channel checks passed 39
cases. Strict Credo passed across 483 files. Deterministic native and fake-Port
tests include modeled unavailability and collection without a live VM owner loss.

Fresh optimized packages and their ordinary Linux/macOS VM, store, upgrade,
draining, consumer/toolchain and HTTP qualification remain pending. The authorized
Linux lab was rechecked inactive with MainPID zero before staging work. No live
crash, forced-owner-loss, persistence-interruption or destructive CLI-race
campaign ran. Historical Linux verification failures remain unresolved, and the
goal and distribution gates remain open.

## October 12, 2026: ordinary qualification exposes backing permissions

The first clean optimized macOS package passed development signing/entitlement,
complete inventory and exact source/policy metadata verification. Ordinary create
succeeded, but normal start returned a native error. The owned startup log showed
virtio-block configuration failure, and both newly cloned backing files retained
the account template's mode 0400. Receipt-bound inspection proved the machine
stopped; deletion through that authentic receipt restored the initial empty
inventory. The failed attempt remains private and is not passing evidence.

SmolBox creation now resolves the existing backing paths through a read-only SDK
manager after pack seeding and makes only these new owned files private/writable
before publishing the receipt. Templates remain immutable. The preparation rejects
symlinks, shared inodes, unsafe modes, wrong ownership and invalid file bounds;
it does not introduce a second disk-seeding or resize algorithm. Asset-preparation
policy advances to version 2, requiring fresh exact package approval. Deterministic
contracts cover permission preservation, backing normalization and refusal cases.

Linux's first clean native run passed 72 engine tests but rejected copying its
302,810,008-byte debug test executable because it exceeds the 256-MiB approved
executable bound. The workspace now retains debug line tables rather than full
dependency DWARF, preserving that bound. This first Linux run remains a failure;
it does not qualify the platform or resolve historical Linux store failures.

The revised complete ordinary macOS native check passed 75 engine, 17 helper and
seven protocol tests, the three specifically selected non-VM worker/guard
fixtures, Python/actual resolver checks, formatting, Clippy, Rustdoc and both clean
inventories. The optimized helper rebuilt successfully. A fresh package and
ordinary lifecycle proof are in progress; Linux must rerun the revised checks.
Crash/CLI-race validation remains deferred. No intentional live owner loss or
persistence interruption was introduced by investigating ordinary start failures.

## October 12, 2026: complete clean SDK formatting and private transfer spools

A second ordinary macOS start attempt showed that normal SDK startup recopies
the mode-0400 template while lazily formatting a raw container disk. Normalizing
permissions only after initial disk creation was insufficient. Creation now
resolves disk formats through the public SDK resolver, opens existing disks and
calls the public `ensure_formatted` API before final backing permission checks
and receipt minting. The SDK supplies formatted-state markers and disk algorithms;
SmolBox neither forges those markers nor rewrites SDK source. The rebuilt package
boots and passes CPU, memory, disk, argv/environment/workdir/user and exit witnesses.

The next ordinary file attempt was refused before dispatch because a historical
owned transfer directory had mode 0755. Transfer directory preparation now creates
mode 0700 explicitly and tightens older owned permissions only beneath the verified
private domain. Descriptor identity checks reject redirected paths, foreign owners,
group/world-writable directories and non-directory objects. Retained spool contents
are preserved. Tests cover the successful tightening and refusal cases. Failed
ordinary fixtures were inspected and deleted through their original package and
authentic receipts, restoring their recorded baseline; failures remain private
evidence rather than passing qualification.

The package builder preserves already approved 1-GiB ext4 template bytes when
both physical length and filesystem geometry match. Unconditional `resize2fs -f`
changed metadata even at the same size, correctly causing an account-template
conflict. Tests distinguish matching geometry from length alone and malformed
superblocks. Compression still regenerates the exact plain bytes. Approved
account templates are never overwritten to resolve a conflict.

The latest complete macOS native check passed 77 engine, 17 helper and seven
protocol tests, the two selected non-VM worker fixtures and selected non-VM guard,
16 Python contracts plus three actual clean resolver checks, formatting, Clippy,
Rustdoc and both unmodified source inventories. Development signature and the
hypervisor entitlement were verified for the newly rebuilt package. Its full
ordinary lifecycle proof remains in progress. Fresh HTTP-only consumers without
Rust passed on Elixir 1.20.4 / OTP 29.0.6 and Elixir 1.18.4 / OTP 27.3.4.15.

Linux's revised ordinary check passed 75 engine, 17 helper and seven protocol
tests, normal sibling-safe child reaping, the selected worker/guard fixtures,
Python/actual resolver checks, format, Clippy, Rustdoc and clean inventories.
The earlier four permission failures were caused by build/fixture files created
under umask 0002; the check runner now sets umask 0077, retaining strict admission
checks. The optimized Linux package is still building. This run predates the final
private spool change, so that revision still requires Linux rechecking. VM/public
consumer, durable store, compatible upgrade/draining and broader HTTP qualification
remain pending. Historical Linux store failures and distribution gates remain open.
No live crash, forced owner loss, persistence interruption or destructive CLI-race
campaign has run.

## October 12, 2026: clean macOS ordinary qualification

The clean package with manifest
`94438f7e1facffcd9203ab4206724ff7dd3f7813101e07cfa5a077a9e9559703`
passed the complete ordinary lifecycle. It witnessed resource limits and
argv/environment/workdir/numeric-user/exit behavior, transferred 1,048,593 binary
bytes, retained data through stop/start and graceful stopped-helper replacement,
and authenticated deletion restored an empty SDK inventory. Its development
signature and hypervisor entitlement were verified. Exact identities and proof
digests are recorded in
[the clean ordinary evidence](../evidence/embedded-port-unmodified-sdk-ordinary.json).

Fresh public Runtime consumers without Rust passed on Elixir 1.20.4 / OTP 29.0.6
and Elixir 1.18.4 / OTP 27.3.4.15, consuming the same Hex archive. Both exercised
execution, binary files, draining that survives normal Runtime restart, versioned
resume and owned deletion; final reserved slots and SDK inventories were zero.
These use the ephemeral store. A separate ordinary public lifecycle using the
real encrypted PostgreSQL adapter passed with its store alive through Runtime
replacement, and again restored the empty SDK inventory. The ordinary PostgreSQL
suite passed 93 tests with 29 live-runtime cases excluded, and its private cluster
was stopped normally after each run. Keys and authority records remain private.

An explicit compatible clean-helper replacement also passed: the mode-2 asset
preparation package with manifest `e100083352f3a83bb709a6e8deeffd95ef8531556443e4dc1427512a73803492`
was replaced gracefully, while stopped, by the manifest above. Both approved
packages use the same clean source, policy, assets and domain generation. The
full receipt and retained file survived a fresh epoch; owned deletion restored
the baseline. This is not patched-package adoption, automatic public store
rebinding or codec rollback qualification.

Linux's first lab session completed its ordinary native check and initial clean
package. Final spool-revision workspace checks passed, but the lab's 45-minute
deadline interrupted the optimized rebuild. No native VM had been launched in
that session. The lab's independent recovery reset its disposable disk, discarding
guest build outputs; that interruption is failed build evidence, not a deliberate
crash qualification case. A fresh bounded session is rebuilding committed
`1bca50b` from verified inputs and will qualify the new package through ordinary
enrollment/lifecycle/child reaping. Linux consumers, ordinary durable lifecycle,
relevant HTTP regressions and the final completion audit remain pending.
Historical Linux store failure evidence and deferred fault/distribution gates
remain open. No crash, forced-owner-loss, persistence-interruption or destructive
CLI-race campaign has been resumed.

The fresh Linux revision's complete native check has now passed: 77 engine,
17 helper and seven protocol tests, one normal sibling-safe child-reaping test,
the two selected non-VM worker fixtures and selected non-VM guard, 16 Python
contracts and three actual clean resolver checks, formatting, Clippy, Rustdoc
and both source inventories. Those completed logs and verified input manifests
were exported off the disposable guest before continuing optimized compilation.
The final ordinary Elixir suite also passed 754 cases (four doctests, six
properties and 744 tests), with 29 live-runtime cases excluded and warnings
treated as errors. Linux optimized-package and ordinary lifecycle qualification
remain active; these checks do not establish live crash qualification.

## October 12, 2026: Linux ordinary consumers, store and helper replacement

The clean Linux package with manifest
`e07fb3d337528df013be943f8f390ca04e30948b324fb73045c5a425a876a91f`
passed normal creation, resource/command witnesses, 1,048,593-byte binary file
round trips, retained stop/start, graceful helper replacement and authenticated
deletion back to the empty baseline. All three normal stopped-helper child
samples were zero. Fresh current and minimum public Runtime consumers without
Rust passed against the same source archive used on macOS. Draining, surviving
store replacement, versioned resume and final zero reservation accounting passed.

The Linux PostgreSQL suite passed 93 tests with 29 live-runtime cases excluded.
A separate public lifecycle using the encrypted PostgreSQL adapter passed normal
Runtime replacement with its store alive and preserved retained data; both SDK
inventory snapshots were empty after owned cleanup. The disposable cluster was
stopped normally. The stripped delivery variant, manifest
`8b6fb5e7ae8b1b47de658648dd8f12912360490721a491ea312cd9926bf2e0db`,
also passed compatible helper replacement using the same clean code, policy,
assets, generation and full receipt, with retained data and normal child reaping.
Logs, exact packages and private authority evidence were exported off the guest.

Both platforms compiled the added public disk-formatting API feasibility witness.
Final clean source checks passed. The ordinary Elixir suite's 754 passing cases
include HTTP compatibility, native/legacy codec and draining contracts; current
and minimum HTTP-only consumers also passed without Rust or native assets. These
do not qualify excluded live-runtime/fault campaigns.

The macOS bare-VM pack regression passed against the exact clean package. It
preserved root/storage snapshots, neutral startup, actual Exit 7, resources and
default root user; rejected explicit VM users; retained a 3,341-byte file across
stop/start and graceful helper EOF; and deleted both owned machines. The Linux
seed likewise created, booted and executed normally, but the private SDK export
tool failed while flattening qcow2: its internal temporary VM lacked the required
SmolBox owner context, and the guard refused boot. Its full saved receipt was
used for cleanup, restoring the empty inventory. That failed campaign is not
passing Linux snapshot qualification. The lab stopped normally with MainPID zero
and Result success before its deadline, after all native owners had exited.

The Linux qualification-tool export boundary and final requirement audit remain
unfinished; the goal remains active. No guard bypass or SDK patch was introduced.
Historical Linux fault-verification failures remain historical and unresolved.
Crash/CLI-race campaigns and distribution approval remain deferred/outside scope.

## October 12, 2026: ordinary migration complete, fault gates remain deferred

The Linux VM-pack fixture boundary is resolved in SmolBox's private authoring
tool. It no longer invokes the SDK's implicit temporary VM exporter. Under its
existing full-receipt/stopped-state/source/domain checks, it resolves disks using
public SDK APIs, converts qcow2 through an explicitly selected approved host
`qemu-img`, and uses SDK asset collection, manifest seeding and packing. Geometry
is bounded and checked. No SDK source changed, no guard was bypassed, no temporary
VM was launched and no consumer dependency or product export capability was added.
The unavailable guest network required staging exact Ubuntu tooling packages;
their cached repository SHA-256 values were checked on host and guest before
installation into the disposable lab. Tool/package hashes are in ordinary evidence.

The revised full bare-VM proof passed on both platforms with the already qualified
clean packages. It preserves root/storage snapshots, neutral startup, actual Exit
7, one CPU, 512-MiB guest memory, two 1-GiB disks and root UID; explicit VM users
are rejected before dispatch. A 3,341-byte binary file survives stop/start and
graceful stopped-helper EOF/reopening. Both saved receipts are authenticated and
deleted; inventory returns to empty. Linux logs/authority evidence were exported,
then the lab stopped normally with MainPID zero and Result success. The earlier
SDK export/guard-refusal trial remains failed historical evidence.

[The completion audit](embedded-port-unmodified-sdk-completion-audit.md) maps every
numbered plan item and gate to the inspected source and authoritative checks.
Ordinary Rust/Elixir/PostgreSQL, current/minimum no-Rust consumers, HTTP compatibility,
codec, draining, compatible clean helper replacement and container/bare-VM surfaces
are verified. Final fixture lint/build, Python contracts/compilation, both complete
SDK inventories and ExDoc with warnings as errors passed. ExDoc initially rejected
repository-only design links from the shipped setup guide; that guide now names
the repository paths without generating nonexistent documentation pages.

The migration's ordinary development contract is complete. Clean source remains
revision `9f446ae00219148ca4a703914f44a8e2fab11655`, with zero active downstream
patches or source rewrites. Exact clean evidence is separate from historical
patched approvals. No private receipt, key or local package is committed; no push
or publication occurred. Future Rustler/Kubernetes implementations remain outside
scope. Abrupt helper/BEAM loss, boot pauses, watcher failure, live persistence
interruption and destructive independent CLI races remain deferred. Historical
Linux fault-verification failures remain unresolved. Developer ID/notarization,
publisher provenance and complete firmware/kernel source/license delivery remain
distribution gates, not ordinary migration completion claims.
