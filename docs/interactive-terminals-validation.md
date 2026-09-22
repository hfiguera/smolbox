# Interactive terminal validation

Development validation on September 22, 2026, for
`feature/interactive-terminal-sessions`, based on
`5862f4523a5eb8b70d2f01fd04a7df6cd1b32a7f`. This is development qualification,
not a production isolation or concurrent-tenant certification.

The [sanitized evidence record](evidence/interactive-terminals.json) identifies
source hashes, per-platform results, cleanup and the limits of retained receipts.
Private logs and key-bearing lab archives are not published.

## Upstream contract

The reference source tree matches the qualified smolvm 1.17.0 distribution.
`src/api/handlers/exec.rs`, `src/agent/client.rs` and the guest agent's PTY code
establish the mutating pre-upgrade start, single executable option, binary merged
output, text resize/exit messages, and lack of durable PTY reattachment.

Codes -1, 124 and 130 can represent internal errors or disconnect cleanup. The
client conservatively refuses to turn them into confirmed terminal results.
A real program that exits with an ambiguous code therefore remains uncertain.
The worker's cleanup targets its direct child and does not guarantee the death of
all descendants. A WebSocket upgrade is not proof of program readiness.

## Real workers

The actual 1.17.0 workers ran on native macOS arm64 and Linux x86_64 inside the
existing disposable nested-KVM lab accessed through `ssh linux`. Both used the
repository's native Python artifact. PostgreSQL-backed scenarios used private
PostgreSQL 17 on macOS and PostgreSQL 16 in the Linux lab.

On both workers, the terminal suite verified:

- An owned managed machine and initial guest dimensions of 37 rows by 91 columns.
- Incremental input and output before shell completion, with a retained file.
- Resize to 43 rows by 113 columns, observed through guest `stty size`.
- Rejection of stop/delete and connection attachment through another controller
  sharing the store while the terminal is active.
- Ctrl-C interrupting a 30-second sleep, followed by another shell command.
- Confirmed exit 7, command-slot release, a subsequent ordinary read of the file,
  explicit deletion, independently observed absence and released reservations.
- A stopped consumer reaching its bounded output limit without unbounded mailbox
  growth or a false confirmed-exit result.
- Abrupt connection loss while a deliberately detached guest descendant continued
  updating its heartbeat. The test explicitly killed that descendant and deleted
  its verified guest afterward.

A `/proc` entry also remained for the direct child during the short disconnect
probe. That observation does not distinguish a live process from a zombie and is
not used as proof of direct-child liveness or termination. The changing descendant
heartbeat is the concrete evidence against treating socket loss as process-tree
termination.

The durable example passed normal shell use and separate-BEAM interruption/recovery
on both platforms. It persisted dispatch, wrote a retained file, halted its
controller, recovered an unknown record without opening another PTY, rejected
conflicting lifecycle work, explicitly resolved after verified quiescence, and
checked a program-launch counter of exactly one. Final deletion verified worker
absence, numerical reservation release, empty SQL port ownership and retained
execution deduplication.

The line-input console was also exercised on macOS with streamed output, its
`:resize` command and confirmed exit 9. It waits for durable completion and command
slot cleanup before shutting down its controller. It does not alter host terminal
settings.

## Failure findings and corrections

A full-suite run exposed an existing reconciliation race: an older running-machine
observation could overwrite a newly accepted stop and defer it for a minute. A
deterministic delayed-response test reproduced the failure. Observation writes now
require unchanged lifecycle intent, state and active-command assignment; renewed
claims alone do not permit applying old evidence to newer work.

The first Linux interruption experiment killed the entire worker cgroup before
recording a machine stop. Upstream startup then removed that formerly running
machine's record and disks. Recovery correctly failed on confirmed absence; no
replacement machine was created. The lab now performs an ownership-verified stop
before draining the dedicated worker, preserves the unresolved command slot during
that drain, and resolves only after verifying the resulting stopped incarnation.
This does not make an observed stop a fence for already-sent worker requests.

An initial console demonstration displayed a live exit before its durable result
was saved, then stopped the controller. The example now waits for both persistence
and slot cleanup. Its uncertain fixture was explicitly stopped, the dedicated
worker drained, and the machine resolved and deleted; the corrected console passed.

The first macOS general regression run lacked the file-transfer cap required by
its security fixture: one case received a client-side output limit instead of the
expected upstream rejection. The dedicated worker was restarted with the documented
1 MiB file-transfer setting and the entire five-case security suite passed.

## Deterministic coverage and limits

In-process protocol peers cover binary/non-UTF-8 data, fragmentation, control frames,
exit/close ordering, malformed and oversized input, bounded incomplete handshakes,
HTTP rejection without retries or redirects, actual TLS verification, authentication,
Unix sockets and redaction. These are protocol tests, not real-worker TLS claims.

Managed tests cover immutable identity, duplicates, conflicting intent, two
controllers, ownership mismatch, pre-dispatch rejection/cancellation, late
cancellation, uncertain opening, consumer disappearance, unattached expiry, retained
ports, closed-buffer retirement, and dispatch/result persistence failure boundaries.
The shared memory/PostgreSQL terminal contract validates typed results, unknown
blocking and retained reservations. A fresh BEAM verifies safe decoding of all new
terminal error-operation atoms.

The complete deterministic suite passed 336 tests with 92.88% line coverage;
26 opt-in runtime cases were excluded from that run and qualified separately.
After the last helper extraction, all 72 affected terminal and persistent-machine
tests passed on Elixir 1.18.4/OTP 27.3.4.15, Elixir 1.19.5/OTP 28.4.1 and
Elixir 1.20.4/OTP 28.5. The PostgreSQL store suite passed 32 tests on each platform;
the existing 25-case durable recovery suite also passed on each platform.

The API does not promise reattachment, transcript recovery, input replay, terminal
sharing, checkpoint terminals, process-tree supervision or disk-loss recovery.
Session-duration maxima are validation bounds; no 24-hour terminal soak was run.
The Linux deployment retains its existing one-CPU, 1.5 GiB charged-memory,
96-task and bounded filesystem controls. These are lab controls, not new library
resource enforcement.

The final Linux campaign returned success after checking all phases, empty worker
inventory and no remaining worker KVM descriptors. The outer VM subsequently
reached its unchanged 45-minute deadline. Its automatic recovery verified the
baseline hash and rebuilt the disposable overlay without replaying tests. The
final per-phase interruption/recovery logs had not yet been exported and were
discarded by that reset. The captured successful campaign status, exported final
terminal/store/normal-run logs, and the earlier complete recovery receipts are
retained as separate evidence; no unexported log is represented as available.
