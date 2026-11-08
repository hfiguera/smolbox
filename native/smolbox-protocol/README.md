# Port protocol 1.4 development contract

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
The new helper implements only 1.4.

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
Background, stdin, networking, registry and optional VM capabilities have no
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
