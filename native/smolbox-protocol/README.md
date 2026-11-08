# Port protocol 2.0 and legacy 1.4 development contracts

This crate defines the first bridge contract and helper-side admission state. It
is independent of hypervisor assets and the engine DTOs, allowing the shared
engine to be used by a future Rustler bridge. The development
[helper](../smolbox-port/README.md) now consumes it. The Elixir decoder and channel
correlation state share its fixtures. Internal supervised Port ownership, durable
assignments and observational recovery are implemented. Explicitly approved
development packages can use public admission; new clean packages still require
ordinary platform qualification, and crash/distribution gates remain separate.

Version 1.4 adds an epoch-bound `{"type":"unavailable","epoch":...}` notice.
It contains no request ID, result, receipt or capacity-release authority. The
helper emits it once after approval when the engine can no longer admit work;
the Elixir bridge quarantines admission while retaining its current helper,
pending streams, credits and native collectors. Existing terminals and controls
remain valid. The notice cannot restore admission or trigger helper replacement.
Queued requests that have not dispatched receive a not-dispatched state error.

Hello 1.4 declares `cancel_grace_ms: 3000`, covering the transfer supervisor's
2.2-second collection budget. The Elixir bridge requires a cancellation grace of
at least 4000 ms for this version. Manifest schema 2 policy binds minor 4 and the
native grace; the approved manifest and Hello must agree. The updated Elixir
bridge also accepts approved legacy schema 1 / Hello 1.3 packages with their
original exact limits. This does not authorize receipt adoption or relabeling.
The legacy helper implements only 1.4.

## Protocol 2 schema and material proofs

The crate and Elixir decoders now also validate protocol 2.0 messages explicitly.
The current engine 0.2.0 helper/package builder emits 2.0, bound by manifest schema
3 and private config schema 2. Expanded parity operations remain pending;
protocol activation does not qualify a rebuilt package. Version-2 Hello
adds a strict SDK identity containing SDK version, source revision and supported
feature versions. It requires the material-proof feature version 2 and exact
source agreement with the package. Approval must bind the complete SDK identity;
legacy approval cannot authorize the new handshake.

Version-2 receipts preserve the original six authority fields and add a bounded
material proof containing revision, current record hash, chain hash and correlated
operation/request identity. Revision zero has no operation and must match the
original material hash. Legacy serialization omits the new fields exactly.
Session admission and terminal creation checks reject receipt/protocol mixing
before native dispatch. Schema validity is not native journal authority.

Packages declaring SDK feature `observability: 1` additionally negotiate six
capabilities and an exact `limits.observations` object. Health, capacity,
metrics and readiness are streamless; measurements require a matching versioned
receipt. Inventory emits capped JSON through credited `file` chunks and binds its
final count/byte total; it never emits receipts. New observation outcomes and
`output_limit` errors are protocol-2-only. Older protocol-2 descriptors retain the
base limits/capabilities, with explicit operator SDK approval in Elixir config.

SDK feature `compact_creation: 1` adds exact `limits.creation`: schema 1,
640-KiB payload, ten chunks, 64-KiB decoded chunk size. Large creation/qualification
workload intent may substitute `features_payload: {schema: 1, chunks: [...]}` for
`features`; they cannot coexist. Durable assignments and the engine retain the
original typed features. The helper records the encoding internally and requires
its explicit SDK gate before admission. No ordinary frame, command, file, event
or credit limit grows. Older descriptors keep their original representation.

The compact binary begins with `SBCF` and byte 1. Integers are big-endian: boolean
and optional markers are one byte (only 0/1), list/map counts are u16 and UTF-8
string byte lengths are u32. Field order is network enabled, host list, CIDR list,
port count and host/guest u16 pairs, workload marker, then entrypoint list, cmd
list, environment count/key-value strings, and optional workdir. Environment keys
are unique. Request count/string bounds apply before allocation; complete bytes
must be consumed. Canonical base64 chunks are nonempty, and all but the final
chunk decode to exactly 64 KiB. Malformed versions, flags, counts, UTF-8,
duplicates, truncation, trailing data and ordinary feature validation fail closed.
The shared `compact-creation-request.json` fixture contains invented identities
and test values, and checks encoding agreement without SDK/VM dispatch.

With compact creation, observation limits additionally bind 8-MiB records and a
32-MiB raw snapshot. The public inventory stream still caps at 4 MiB; private
workload metadata is never included. Without that feature, observation descriptors
retain the original 256-KiB/4-MiB read bounds. Package policy must match both the
creation and observation limits before launch/Hello approval.

SDK feature `job_resources: 1` binds `limits.jobs` and the package's `job_limits`:
four engine work slots, two engine observation slots, four worker children,
64-MiB staging, 32 reserved parent descriptors, eight descriptors of control
headroom, 4-MiB SDK request frames and 64-KiB reply overhead. OS descriptor checks
include currently open descriptors and outstanding reservations. Worker children
exclude VMMs, which still require their independent machine/auxiliary accounting.
The observation lane has separate engine admission and two dedicated Port
dispatch threads. Health/capacity/metrics/readiness/list/measurements use that
queue; mutation and command/file work retain four dispatch threads. For approved
protocol-2 job descriptors, two of the existing 32 in-flight request identities
are reserved for observations, so at most 30 work requests may be retained.
Both queues still share the original global request/byte/output caps. Cancel
and credit retain independent reader/control dispatch. Deterministic bridge
evidence covers four blocked work calls, a full work queue, one blocked
observation and a second successful observation; broader interference and
platform qualification remain pending.

File and foreground execution leases share this engine pool. A collected file
result retains its spool/leases through forwarding; unresolved collection moves
them into the existing owned collector, quarantines admission and cannot release
capacity on a timeout. File worker SDK I/O uses a private Unix relay that checks
response lengths before forwarding their headers to the SDK allocator, with a
cap derived from allowed decoded output plus base64/metadata overhead. Relay
bodies are copied in 64-KiB chunks; the SDK still implements guest operations.
SDK feature `streaming_exec: 1` requires `buffered_exec: 1` and adds
`exec_stream` with the same compact command input limits and nil stdin. The
`streaming-command-request.json` fixture is shared by Elixir and Rust. Streaming
stdout/stderr use existing byte/event credit while the command is running; final
command completion carries actual guest Exit separately. Background/file/log
outcomes cannot substitute for it. This capability is protocol-2 only and requires
store admission `native_streaming_commands: 1` after upgrading all v17 readers.
Older descriptors retain their previous command bounds and wire operations.

The job_resources descriptor alone does not enable buffered stdin, PTY, registry
or artifact jobs, and their remaining accounting/qualification gates stay pending.

The subsequent `buffered_exec: 1` feature requires `job_resources: 1` and adds
`exec_buffered` plus exact `limits.buffered`/package `buffered_limits`: 704-KiB
compact payload, eleven chunks, 8-MiB job metadata and 64-KiB stdin. Job limits
add 32-MiB aggregate metadata only for this descriptor. Legacy job descriptors
omit that field. Receipt mode, stream credit and terminal correlation remain
unchanged; buffered execution emits stdout/stderr chunks and a command outcome.

SDK feature `terminals: 1` requires `buffered_exec: 1` and advertises
`terminal_open`, negotiated terminal limits, initialized-before-output evidence,
ordered attach/input/resize/close controls and a distinct binary terminal stream.
Only whole FIFO consumption restores byte/event credit; consumed transcripts do
not use the command lifetime event/output cap. A confirmed terminal outcome binds
valid guest Exit, exact delivered byte totals and owned worker collection.
Native retained records use v17 and require `native_terminal_sessions: 1` before
Runtime enrollment. Caller/observer binding, durable slot accounting and no-replay
remain enforced; `Client.open_terminal` stays HTTP-only. Ordinary platform/package
qualification remains pending.

Buffered requests may carry `command_payload: {schema: 1, chunks: [...]}` instead
of `command`. Its decoded layout is `SBCM`/byte 1, u16 argv count/u32-length UTF-8
strings, u16 environment count/key/value strings, optional workdir/user/stdin
markers (0/1) and strings, then u64 output cap. Only stdin permits NUL. Chunks
and request validation remain bounded, mutually exclusive representations reject,
and all bytes must be consumed. The synthetic `buffered-command-request.json`
fixture tests cross-language encoding. No ordinary frame/file cap grows.

The engine's worker spool carries immutable private metadata and stdout/stderr
lengths plus SDK Exit evidence. File acknowledgment is not a command result.
Only a correlated command-completed event, successful owned worker collection
and verified output spool can supply Exited; worker EOF/exit alone cannot. Late
results after retirement remain unverified. This implements buffered stdin;
Registry/artifact workers and ordinary guest qualification remain pending.

The shared `hello-v2.json`, `created-v2.json` and `inspect-v2-request.json`
fixtures are synthetic protocol data, not VM qualification or package approvals.
The Elixir channel preserves monotonic correlation and sticky unavailable
admission for version 2. Durable version-2 assignments selectively require the
v17 store codec and explicit `native_material_proofs: 2` negotiation; old v16
receipts remain readable and cannot be promoted or mislabeled as v17 authority.

Version 1.3 adds `inspect_creation`, carrying the complete original approved
creation intent without a receipt. Its streamless `creation_presence` terminal
contains only `absent` or `unverified`; it cannot mint a receipt or satisfy another
operation. The engine checks existing SDK records/reservations, local handles and
VM material without preparing the artifact, starting a guest or reaping stale
reservations. Errors remain errors. This query permits explicit deleted resolution
of a lost creation reply after quiescence; present material remains reserved.
Automatic recovery and cleanup still leave lost receipts unverified. The budget
is at most 30 seconds. Exact 1.2 peers are rejected, and approved package identity
must change with the protocol version.

Version 1.2 added `qualify_creation` and its streamless `qualified` terminal. This
query checks the approved pack's digest/footer/manifest, supported resources and
guest-user policy before VM reservation or retained-slot attachment. It may write
immutable artifact-cache bytes, but cannot create a VM record, VM directory or
handle. Creation independently repeats qualification before VM mutation. Query
acceptance or success provides no receipt, Exit or creation authority. Exact 1.1
peers are rejected; package approval and the protocol tuple change together.

Version 1.1 adds an independent event-count credit window. The unreleased 1.0
development protocol is rejected by 1.1 peers; its byte credit alone could not
bound message overhead from tiny chunks. Package/build approval and the exact
protocol tuple must change together. No released consumer compatibility is claimed.

Frames contain a four-byte unsigned big-endian length followed by UTF-8 JSON.
The decoder rejects zero/over-1 MiB lengths before reading or allocating the body,
partial frames, duplicate object keys at any depth, trailing data and malformed
JSON. Depth is limited to 16, collections to 256 elements, strings to 128 KiB and
keys to 128 bytes. DTO decoding additionally rejects unknown fields, unknown
variants, invalid identifiers, unsupported resource ranges and unsafe paths.
Validation errors contain only fixed redacted text. DTOs do not implement Debug.

The helper's first response is `{"type":"hello","hello":...}`. Hello carries
major/minor, a random 32-character lowercase hex epoch, stable target/generation,
exact engine/source/build/assets identities, platform/architecture, capabilities,
limits and ready/rejected preflight. The bridge sends `approve` with the exact
approved Hello echoed back. Approval requires ready preflight and exact equality;
unknown versions, changes to domain/assets/limits and repeated approval fail.
The handshake is a declaration of the local package, not remote attestation.

After approval, `request` includes epoch, positive ID, budget in milliseconds,
initial decoded output credit, initial event credit and a tagged `operation`
object. IDs must strictly
increase across the whole epoch, including pre-dispatch rejected requests. IDs
and sequence values stay within JSON's exact integer range (2^53 - 1). This
stricter unique-ID rule avoids an unbounded completed-ID table. Budgets are
positive durations, with a one-day command maximum and ten-minute file maximum;
helpers must charge queue time and never compare the BEAM's absolute clock.

Operations are qualify_creation, inspect_creation, create, inspect, start, stop, delete, exec,
read_file and write_file. Qualification accepts exact approved artifact identity,
resources and an optional user, requires no receipt, emits no stream/upload data,
and has a maximum 30-second budget. Its successful terminal is valid only for this
query. Qualification also streams the sidecar's asset inventory, nested tar
archives and disk superblocks before reservation. Pack format and bounds are
documented in the helper guide; runtime faults and platform qualification remain
separate admission gates.
Creation accepts approved local artifact identity, exact resources, name,
owner/incarnation and bounded non-reserved labels. VM lifecycle, command and file
operations require a complete creation receipt matching the domain. Exec accepts argv,
environment, optional absolute workdir/qualified user, and output-byte cap.
On the legacy path, background, stdin, networking, registry and optional VM capabilities have no
accepted representation. Validation does not itself prove artifact approval or
image-qualified users; engine and configuration checks still apply. The current
qualified explicit-user policy is numeric UID or UID:GID below the u32 sentinel
on container packs. Named users and explicit users on VM packs are unsupported.

At most 32 requests are accepted. Overload, absent capability and wrong-domain
receipt return `terminal` sequence 0 with a safe error and `not_dispatched`,
without admission. `accepted` sequence 0 acknowledges scheduling only. Events
start at sequence 1, increase without gaps, and carry stdout/stderr/file binary
chunks as canonical padded standard base64. Chunks are at most 64 KiB decoded.
A terminal uses the next sequence and removes the request; a second terminal or
later event is invalid. An accepted request must end once while the channel is
healthy. Channel loss requires conservative bridge reconciliation.

Each stream starts with at most 256 KiB output credit and 64 event slots. Emission
debits decoded bytes and one event slot. A `credit` message carries decoded_bytes
and events; bytes must acknowledge a prefix of previously emitted data and events
must exactly equal the number of fully consumed chunks. Partial consumption does
not retire an event slot. Neither window can grow its original allowance. The
bridge replenishes credit only after consumption. At 32 requests, no more than
2048 output events can remain outstanding independently of their byte size.
Session rejects credit exhaustion immediately; the helper first allows a finite
one-second wait for replenishment, bounded by the operation's remaining time.
Per-request event count is capped at 65536, with room left for
terminal completion. Separate aggregate output queues must enforce the declared
8 MiB decoded and 12 MiB encoded limits, including envelope overhead. Queue and
credit bounds are complementary; Session does not implement queues or I/O.
The BEAM channel additionally retains completed subscriptions and their charged
output until consumption. Receiving a terminal does not authorize freeing unread
observer output and accepting an unbounded succession of new subscriptions.

Write requests declare total_bytes and safe file options. Subsequent `upload`
messages use the same epoch/ID, exact decoded byte offset and base64 chunks.
The helper must spool chunks to an owned capped temporary file and dispatch no
native write until the declared total is present. A zero-byte write needs no
upload. Duplicate, gapped, excess or wrong-operation uploads fail. Spool failure,
timeout, cancel and EOF must dispose of the spool and complete conservatively.

Cancel and credit do not require free admission capacity. Late controls for a
completed ID are harmless completion races; wrong epochs/future IDs are protocol
errors. A channel violation makes the target unavailable rather than generating
fictional native outcomes. Native cancellation tokens and reader independence
are the helper's responsibility, outside this state machine.

Terminal outcomes distinguish qualification, creation presence, created receipt, typed observation, command,
file and safe error. Command completion is separate from observed_exit,
dispatch, running_observed and decoded output total. Only a valid `exited` stream
with an observed Exit can supply an ordinary command result; zero without Exit
is never inferred. An error/deadline/cancel/output failure can retain a real
observed Exit while disqualifying success. File completion separately retains
native acknowledgment. Completed streams must account for all delivered bytes;
an acknowledged download with truncated forwarding cannot claim completion.

The checked-in [request](fixtures/exec-request.json) and
[terminal](fixtures/exec-terminal.json) fixtures contain invented test identities.
Contract checks cover handshake, limits, control races, ordering, uploads,
base64, unsupported fields and conservative terminal evidence. These checks do
not qualify slow OS readers, process death, native dispatch, or the BEAM bridge.

SDK feature `background_exec: 1` requires `buffered_exec: 1` and adds the separate
`exec_background` capability. Compact input uses the same SBCM schema with nil
stdin. Guest lifetime timeout is absent; the request budget bounds host launch
observation and owned worker collection. This is retained-image buffered launch,
not a foreground stream or terminal. The only successful outcome is
`{result: "launched", pid: positive-u32}` with no stdout/stderr/file events.
The canonical `pid=N\n` acknowledgment must fit the original output budget.
Foreground Exit, file ACK, zero/malformed PID, duplicate or retired proof cannot
confirm launch. PID evidence authorizes no readiness/liveness inference or
PID-based termination. Workers use the public SDK run_background API through
bounded agent I/O and retain the original image overlay/user/mount context.

Native launch intent/results preserve the existing Command/LaunchResult and v17
shapes. Runtime additionally requires `native_background_launches: 1` from the
store before enrolling a background-capable package. Older v17 material readers
cannot opt into this feature using their material-reader capability alone. The
[background input](fixtures/background-command-request.json) uses synthetic
identities and shares exact compact bytes with the Elixir codec. Deterministic
wire/worker models and ordinary non-VM SDK checks are evidence for these bounds;
ordinary guest/platform/package qualification remains pending.

SDK feature `logs: 1` requires the buffered/job contract, binding `limits.logs`
to package `log_limits`: 10,000 lines, 131,064 delivered bytes per line, 1-MiB raw
partial lines, 8-MiB public output, 6-MiB buffer reservation and 100-ms polling.
The reservation shares the existing 32-MiB metadata pool and four work slots;
followers never consume the two observation threads or a machine mutation lock.

`logs {receipt, tail, follow, max_bytes}` uses a distinct `log` event stream.
Port frames each engine text line as big-endian u32 length plus UTF-8 bytes,
including zero-length lines; 64-KiB events may split prefixes/text arbitrarily.
Line bytes include one newline for public accounting; wire bytes add three
bytes per line. The separate Logs outcome binds completion, line/public/wire
counts and delivered credit. Completed snapshots require exact framing/counts;
follow deadline/cancellation, partial framing or consumer loss cannot become
completion or guest Exit. Missing-console errors are protocol-2 `not_found`,
not creation-absence authority. Elixir validates complete UTF-8 and aggregate
counts before returning LogResult, and detaches failing user callbacks.


## Unadvertised terminal session contract

Protocol 2 can represent `terminal_open`, `terminal_opened`, `terminal_control`
(attach/input/resize/close), the distinct `terminal` binary stream and terminal
outcomes with actual Exit and `worker_collected`. Hello binds terminal capability
and limits to `terminals: 1` plus buffered/job support. The current package does
not declare that feature and helper dispatch rejects terminal open before native
work; schema support alone cannot enable it.

The shared terminal-open fixture and Rust/Elixir contracts preserve public bounds,
request/domain identity and ordered control sequences. Input before attach,
controls after close, duplicate/future identity and invalid shapes reject. Whole
matching event consumption restores terminal byte/event credit; partial credit
cannot enlarge a window. Continuous consumption can exceed the ordinary command
65,536-event cap without retaining a cumulative transcript. Legacy command/file
caps and other stream semantics remain unchanged.

Only a valid guest Exit plus exact worker collection can report exited terminal
completion. Output totals match all delivered terminal bytes. Host-child
collection is separate from SDK dispatch: a collected pre-dispatch failure can
have no guest Exit. Background/file/command results cannot satisfy terminal
completion. Uncertainty may preserve observed Exit without qualifying success.
Live bridge routing, native reader/store admission and platform qualification
remain pending; crash validation stays deferred.
