# Telemetry and operator inspection

SmolBox emits optional asynchronous `:telemetry` observations from explicitly
started managed runtimes. Stored execution evidence is authoritative. Notifications
are lossy: they can be dropped, repeated during reconciliation, or interrupted
between stage start and stop. They are unsuitable for driving workflows, billing,
receipts, or exactly-once delivery. Low-level `SmolBox.Client` calls do not emit
these managed lifecycle events.

Use `SmolBox.Telemetry.events/0` to register a handler with
`:telemetry.attach_many/4`. Prefer a named external function. The host owns
attachment, detachment, export and retention. A handler should finish promptly;
any downstream queue or service it uses needs its own bounds and redaction policy.

## Events and measurements

All names start with `[:smolbox]`. Execution events carry `count`, stored
`version`, `observed_at_ms`, `age_ms`, and the current reservation measurements
`reserved_slots`, `reserved_cpus`, `reserved_memory_mb`, `reserved_disk_gb`.
Released reservations report zero. An observed result adds `exit_code`,
`stdout_bytes`, `stderr_bytes` and numeric `truncated` (0 or 1). Unknown command
outcomes have no fabricated exit measurement. Persisted cancellation intent adds
the original `cancel_requested_at_ms`; repeated cancellation does not reset it.

| Suffix | Meaning and additional measurements |
| --- | --- |
| `[:execution, :accepted]` | Store acknowledged insertion of a new identity; duplicate lookup emits no second acceptance |
| `[:execution, :reserved]` | Store acknowledged resource assignment; `queue_wait_ms` is elapsed stored wall-clock time since acceptance |
| `[:execution, :updated]` | A meaningful state/evidence/result/collection/cleanup write was acknowledged; lease and scan-only writes are omitted |
| `[:execution, :cancel_requested]` | Store acknowledged cancellation intent; inspect evidence for actual termination |
| `[:execution, :released]` | Store acknowledged capacity release |
| `[:stage, :start]` | Attempt started; `system_time_ms` gives the observation timestamp |
| `[:stage, :stop]` | Attempt returned or raised; `duration_ms` is monotonic elapsed time |
| `[:worker, :status]` | Worker status changed or drain was explicitly requested; `count: 1` |
| `[:store, :error]` | A store call returned an error; `count: 1`, finite `operation` and `category` metadata; expected not-found reads can also appear |

Stage metadata identifies `:preparation`, `:execution`, `:collection` or `:cleanup`.
Preparation includes machine preparation and input staging. Execution covers the
controller's command observation attempt, including transport; it is not isolated
guest CPU time. Collection covers output retrieval and persistence. Cleanup
measures each active reconciliation attempt, excluding retention waits and
controller downtime. Start has outcome `:pending`; stop has `:returned`, `:error`
or `:exception`. A returned attempt can still record an unknown or failed execution;
this category does not certify business success. No exception reason is emitted.

Execution `:updated` metadata includes persisted `state`, `evidence`, `collection`
and `cleanup`. This exposes dispatch intent, observed running/exit, unknown outcome,
collection failure and cleanup failure without suggesting that a notification is
a worker receipt. Wall-clock differences are clamped at zero and depend on the
host's clock discipline. They are not cross-host monotonic durations.

## Payload privacy and cardinality

Events include configured `runtime` and `namespace`. Execution/stage events add
bounded `scope` and `execution_id`; worker observations add `worker_id` and finite
`platform`/`status`. Identifiers belong only in access-controlled traces. Choose
finite event kind, stage, platform and outcome categories for metric labels.
Do not label metrics with arbitrary runtime, namespace, scope or worker IDs.

Payloads omit command arguments, environment, stdin, business metadata, fingerprints,
artifact paths/digests/bytes, stdout/stderr and raw errors. Numeric measurements
are bounded signed integers. Malformed projections are discarded rather than
substituting raw data. No opt-in raw-output sink is provided by this library.
Third-party HTTP telemetry, exporter logging, and host code remain outside this
contract; inspect those separately before exporting from a sensitive environment.

## Bounded delivery and failures

Runtime options `telemetry_max_pending` (default 128, range 1..1024) and
`telemetry_timeout_ms` (default 100, range 1..1000) control delivery. One handler
delivery process runs at a time per runtime. The pending cap includes active,
queued and reserved/in-transit notifications. Overflow is dropped before mailbox
delivery; producers do not wait for exporters. Each event is a small bounded
projection, independent of command/file/output length.

A handler deadline terminates that delivery process. Its execution task and the
coordinator continue. Handler failure follows `:telemetry`'s handler behavior;
ordinary exceptions can detach that handler. Dispatcher failure restarts the
notification child separately from the work subtree. This is ordinary OTP fault
isolation, not protection against hostile BEAM code, exhausted VM resources or
repeated failures exceeding supervisor restart intensity. Handlers can spawn other
work, and that work is outside this dispatcher's supervision and capacity bound.
Scheduling pauses can delay timer handling; the timeout is not a real-time limit.

`SmolBox.telemetry_stats(runtime)` returns `{:ok, stats}` with `available`, `epoch`,
`limit`, `pending`, `processed`, `dropped` and `timed_out`. These are ephemeral
counters. `processed` means the delivery process returned normally, not that an
exporter durably received the event or every attached handler succeeded. Timeouts
are counted separately from drops. Concurrent rejected offers can briefly make
the pending snapshot exceed the limit while returning their speculative credits;
the number of accepted event messages remains bounded.

Dispatcher restart resets counters and changes `epoch`. Two consecutive idle
sweeps also retire credits abandoned by producers that died before sending. Late
messages from that retired epoch are discarded. Consequently, compare counters
only within the same epoch; missing events and reset counters are expected. Never
use them to reconstruct durable execution accounting.

## Inspecting authoritative state

Hosts must authorize all inspection calls. `SmolBox.fetch/3` returns the stored
record, including the full specification and result: unlike telemetry, it is a
protected data API. Use `state`, `evidence`, `version`, `cancel_requested_at_ms`,
`next_due_at_ms`, `deadlines`, `result`, `artifacts`, `collection`, `cleanup`, `last_error`
and `reservation` to distinguish command outcome, output availability and remaining
resource ownership. Do not expose the full record to an unauthenticated client.

`SmolBox.workers/1` gives version/qualification, architecture/platform, recent
health, drain status, allocation floors and configured capacity. Capacity is a
host declaration, not measured free resources. `SmolBox.audit_worker/3` provides
bounded read-only orphan inspection; it never adopts or deletes resources.
`fetch`, `workers`, `telemetry_stats` and `audit_worker` are observational.
`cancel` records intent that can lead to owned-guest termination. `reconcile`
advances observation/cleanup of existing evidence and never authorizes replay.
A new authorized execution requires a new identity via `submit`.
