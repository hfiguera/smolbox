# Interactive terminal sessions

Use an interactive terminal when a person or agent needs to send input while a
program runs: shells, REPLs, debuggers and terminal tools. A foreground command
returns output and an exit result; background execution returns launch evidence;
an interactive session provides an ongoing terminal byte stream.

This API supports managed persistent **image machines** on qualified smolvm
**1.17.0**, and a low-level client for hosts that manage lifetime themselves.
Disposable execution and checkpoint terminals are unsupported. No process
supervisor, automatic reconnect, input replay or guest-session reattachment is
provided.

## Open and use a managed terminal

Use an owned, running machine with an approved artifact and profile:

```elixir
{:ok, terminal_spec} = SmolBox.Terminal.Spec.new(
  program: "/bin/sh", cols: 100, rows: 30,
  session_ms: 300_000, idle_ms: 60_000
)
{:ok, spec} = SmolBox.ExecutionSpec.new(
  scope: scope, id: "shell-001", artifact: artifact,
  profile: profile, command: terminal_spec
)
{:ok, execution} = SmolBox.Terminal.open(runtime, machine, spec)
{:ok, terminal} = SmolBox.Terminal.attach(runtime, execution, 30_000)
:ok = SmolBox.Terminal.input(terminal, "pwd\n")
{:ok, {:output, bytes}} = SmolBox.Terminal.next(terminal, 5000)
:ok = SmolBox.Terminal.resize(terminal, 120, 40)
:ok = SmolBox.Terminal.input(terminal, "exit 7\n")
```

Continue pulling events until `{:closed, outcome}`. Output can arrive in any
chunk boundaries; one input line need not produce one output event. A confirmed
outcome is `{:ok, %SmolBox.Terminal.Result{exit_code: code}}`; an uncertain outcome
is `{:error, %SmolBox.Error{}}`. `next/2` wraps each event in `{:ok, event}`.
A caller read timeout returns an `:expired` error and leaves the session running.

`open/3` returns **durable acceptance**, not readiness. `attach/3` binds the calling
process to the existing live connection on the runtime that owns it. It does not
open another guest shell. Even a successful WebSocket upgrade does not prove the
program started; upstream starts it asynchronously. Verify readiness through the
program's protocol or observed output when required.

The bound process owns input, resize, close and event consumption. Another process
cannot reuse its handle. Applications should route authorized frontend requests
through that owner. Another controller sharing the store can inspect or cancel
the durable execution but cannot take over its live stream. Hosts must authorize
scope access; durable IDs and handles are not authentication credentials.

`Machines.submit/3` also accepts this execution specification. Existing
`SmolBox.fetch/3`, `await/3` and `cancel/3` operate on its durable identity.
`SmolBox.submit/2` rejects interactive intent before acceptance or worker mutation.

For low-level use:

```elixir
{:ok, terminal} = SmolBox.Client.open_terminal(client, machine_name, terminal_spec)
```

Low-level callers supply their own ownership, concurrency, retention and recovery
controls. The default client transport is required: custom HTTP adapters are
rejected rather than silently bypassed. The WebSocket connection uses Mint and
MintWebSocket, with verified TLS and the same configured endpoint, bearer token
and CA. HTTP origins map to WS and HTTPS origins to WSS. Unix sockets use the
configured loopback origin and socket path. No redirect or automatic retry occurs.

## Supported options and budgets

Upstream's endpoint accepts one executable as `cmd`, with `cols` and `rows`.
`program: "/bin/sh"` selects a shell explicitly. SmolBox does not insert a shell,
concatenate an argument vector, or silently emulate unsupported options. `argv`,
`env`, `workdir`, `user`, `stdin`, ordinary command timeouts and `background` are
not terminal specification options. Send interactive input separately.

| Terminal option | Default | Bounds and meaning |
|---|---:|---|
| `program` | `/bin/sh` | Nonempty UTF-8 executable name/path, at most 4096 bytes, no NUL |
| `cols`, `rows` | 80, 24 | Each 1–65535, including resize requests |
| `session_ms` | 30,000 | 1,000–86,400,000 ms, finite observation budget |
| `idle_ms` | 30,000 | 1,000–`session_ms`, inactivity of application input/output |
| `close_ms` | 1,000 | 1–5,000 ms to observe explicit local closure |
| `attach_ms` | 5,000 | 100–30,000 ms for a managed connection to acquire a consumer |
| `max_buffer_bytes` | 262,144 | 1,024–1,048,576 bytes of unread terminal output |
| `max_input_bytes` | 16,384 | 1–65,536 bytes per input call |

The managed session budget must fit the immutable, host-approved profile's
`execution_ms`. Its absolute deadline starts with first dispatch intent, before
preflight and upgrade, and does not reset on observation or restart. The output
buffer must fit the profile's `max_output_bytes`. Configure a longer approved
profile before creating the machine if needed; existing machines cannot silently
acquire a different profile.

Preflight and handshake share the earlier of the worker's operation budget and
30 seconds. Connection setup also respects the worker's connect budget. The
WebSocket then uses its own session and idle budgets; the ordinary HTTP receive
and operation deadlines do not silently truncate an established terminal.
Low-level session time starts after handshake. Managed observation additionally
remains subject to its earlier persisted deadline. Lease renewal continues while
opening and observing a session.

These budgets end observation and close the connection. They are not promises of
guest lifetime enforcement. Ctrl-C (`<<3>>`) and Ctrl-D (`<<4>>`) are terminal input;
the guest's terminal mode and program determine their effects.

## Bounded streams and privacy

Mint supplies HTTP/TLS connection handling and upgrade verification; MintWebSocket
supplies masking and frame decoding. Reusing those libraries avoids maintaining
another WebSocket implementation. SmolBox adds byte limits before fragment assembly
and owns passive reads and bounded delivery. Both dependencies are exercised by the
package's current and minimum-dependency compatibility checks.

Output contains arbitrary bytes and terminal control sequences, with merged PTY
stdout/stderr. It is not assumed to be UTF-8, line-oriented or safe to embed in HTML.
Applications displaying terminal output must use an appropriate terminal renderer
and their own authorization and escape-sequence policy.

The connection reads passively and the consumer pulls output. Network output is
never pushed repeatedly into the consumer's mailbox. Each frame is bounded at
64 KiB, fragmented messages are bounded, and at most 1024 unread chunks fit within
the configured byte buffer. Compression is disabled. Buffer exhaustion closes
observation with `:output_limit`, preserving uncertainty instead of pretending that
dropped output established completion.

Input calls are synchronous and limited individually. Total input and resize JSON
bytes per connection are also capped by the worker's `max_request_bytes`, limiting
what SmolBox can feed into upstream's unacknowledged input queue. A successful send
means bytes were handed to the connection, not that the guest consumed them. Socket
writes have a bounded timeout of at most one second. A consumer must not create
unbounded queues outside this API.

Finished buffers are ephemeral: they retire after 30 seconds or after the final
event is consumed. Opening more managed sessions can retire already-closed buffers
when the runtime's live registry reaches `max_active`; durable completion evidence
remains available. This keeps finished buffers from accumulating independently of
active execution limits. Drain each stream promptly.

Terminal input and output are not stored in execution records, fingerprints,
telemetry or application transcripts by this library. The specification and
redacted outcome are persisted; protect the store and its keys. Session process
status is redacted. Host debuggers, application logging and third-party transport
instrumentation are outside that privacy boundary. Do not log terminal bytes or
credentials by default.

## Identity, lifecycle and uncertainty

Each session uses its own scoped execution ID and immutable specification. A
matching duplicate returns that identity while opening, active, completed,
unknown, or after machine deletion. Changed intent conflicts. A duplicate never
opens a replacement shell or replays input.

A managed terminal holds the same command slot as ordinary managed commands across
controllers sharing the store. Opening, active, closing and unresolved sessions
block subsequent commands and stop/delete requests. No input staging or final file
collection is implicit; nonempty input/output manifests are rejected. Existing
background processes can still access files concurrently with a terminal.

Confirmed exit is persisted as `state: :completed`, `evidence: :exited`, with a
`Terminal.Result` and no transcript. Slot release may follow live event delivery;
observe `Machines.await/3` and check `active_execution: nil` before another command.
The machine, disks and port reservations remain until explicit lifecycle actions.
Program exit does not prove all descendants or background services stopped.

Upstream also uses synthetic status values. This implementation conservatively
keeps `-1`, `124` and `130` uncertain; the wire cannot reliably distinguish the
relevant internal/disconnect cases from an application's identical exit code.
Malformed notifications, socket loss and close without trustworthy exit evidence
are not successful command completion.

`close/1` requests a WebSocket close and observes it within `close_ms`. An uncertain
local close is identified by `last_error.operation: :terminal_close`; idle/session
expiry and consumer disappearance have their own operation values. A consumer
exiting closes observation. A caller disappearing before attachment does not revoke
accepted durable intent: an eventual unclaimed connection expires under `attach_ms`.

Cancel before dispatch prevents opening when the controller observes that intent
before committing dispatch. After dispatch may have happened, cancellation closes
observation and retains uncertainty. Cancelling a completed record does not erase
its confirmed result. No PID-based killing is added.

## Recovering after controller or connection loss

Restarting a controller recovers durable session identity and evidence, not a live
terminal connection. A potentially dispatched session with no saved exit becomes
unknown and blocks reuse. Never automatically reopen it or replay keystrokes.
A recorded known exit remains known even if the controller crashed before slot
cleanup. Earlier accepted intent that has provably not dispatched can still receive
its first dispatch through the existing execution workflow.

Use the existing [quiescent resolution procedure](persistent-machines.md#cancellation-and-uncertain-outcomes)
for uncertain sessions: fence/drain old controllers and requests already sent to
the worker, verify ownership, then stop the machine or verify explicit deletion,
and resolve the inspected durable record. Store fencing, an expired lease, or a
stopped observation alone does not drain old worker requests. Do not infer confirmed
absence from an unavailable worker or store.

If draining uses a restart of the dedicated worker, record an ownership-verified
stop before killing its guest processes. Upstream 1.17.0 startup deletes records
and disks of formerly running machines whose processes have died. The preliminary
stop preserves supported disks; it does **not** release the slot or establish
quiescence. Drain old requests, restart, and verify the final stopped incarnation
before resolution. Lost worker disks cannot be recovered by this API.

Upstream's dedicated agent connection attempts to kill its direct PTY child on
disconnect. This is not a reliable contract for every descendant, nor evidence that
a disconnected caller can always observe. Machine stop/start retains supported
persistent files but not the terminal connection or running program. Start another
session deliberately with a new execution ID after safe resolution.

## Persistence and upgrades

Adapters must advertise `interactive_terminal: 1` and `extended_execution: 1`.
The memory and durable PostgreSQL example implement both. Terminal executions use
codec **v7** with `Terminal.Spec` and `Terminal.Result`. Ordinary foreground and
background records retain their previous encoding and fingerprints; older envelopes
cannot carry terminal semantics. No new SQL column migration is needed in the
example; its existing encrypted payload and state projections are reused.

Upgrade all controllers, readers and adapters sharing the worker/store authority
before enabling terminals. Older readers cannot decode v7. Disabling new sessions
does not make retained v7 history safe for rollback. Keep upgraded readers or use a
reviewed identity-preserving conversion; never drop undecodable records or treat
those records as absence. Memory mode does not survive a BEAM restart.

## Runnable examples and qualification

Follow the durable host's PostgreSQL, artifact and key setup, then use a fresh
`SMOLBOX_EXECUTION_ID` and `SMOLBOX_STORE_PARTITION`:

```sh
MIX_ENV=test mix run scripts/terminal.exs run
```

This opens a shell, writes a retained file, resizes, observes exit, runs an ordinary
command to read the file, and explicitly deletes the machine with reservation checks.
The `shell` phase provides a line-input console with streamed output and `:resize`,
`:interrupt`, `:eof` and `:close` controls. It does not change the host terminal's
settings or implement a full raw terminal UI. It retains the machine; use the
`delete` phase after confirmed slot release, or recover uncertainty first.

The `interrupt` phase deliberately halts the BEAM with a session active. Before
running `recover` with the same partition and keys, independently drain/fence the
old controller and its worker requests. Only then set `SMOLBOX_TERMINAL_QUIESCED=true`.
When draining by worker restart, first run `stop-for-drain` to persist a verified
stop, then restart the dedicated worker and verify its old requests are gone.
The recovery phase verifies unknown blocking, explicitly resolves after stopping
the owned machine, checks the retained file and a program launch counter of one,
and explicitly deletes. The environment flag is an operator assertion, not a probe.

The opt-in `test/terminal_runtime` suite exercises actual PTY behavior. In the
prepared disposable Linux lab, `bash scripts/lab/interactive-terminal.sh` also runs
the durable phases. Its worker restart retains private disks while stopping and
verifying old processes; ordinary lab `start` resets those filesystems. The campaign
keeps the existing CPU, memory, task, disk, worker and outer-VM deadlines.

Capture the campaign on the **physical Linux host**, outside the disposable VM.
Copy `scripts/lab/capture-terminal.py` there and run it with a new private evidence
directory under `/var/lib/smolbox-lab/evidence`. For a focused recovery rerun:

```sh
python3 capture-terminal.py /var/lib/smolbox-lab/evidence/terminal-recovery-001 \
  bash /home/humberto/smolbox-lab-bootstrap/guest-ssh.sh \
  env SMOLBOX_TERMINAL_ATTEMPT=receipts001 SMOLBOX_TERMINAL_SCOPE=recovery \
  bash /opt/smolbox/source/scripts/lab/interactive-terminal.sh
```

Omit `SMOLBOX_TERMINAL_SCOPE=recovery` for the full campaign. Use a fresh attempt
and evidence directory each time; failed phases are never replayed automatically.
Each phase streams output immediately, with its exit status and log SHA-256 at the
end. The host capture syncs incoming output to disk, keeps partial failure output,
and records its own exit status and digest in `capture.json`. It fails at 16 MiB or
15 minutes; each guest phase is capped at 240 seconds and 2 MiB of log output.
These bounds do not extend worker or VM deadlines. A lost connection remains a
failed/incomplete capture even when earlier phases passed. Capture exit zero alone
does not replace checking the phase results and final cleanup assertions. Guest
keys and object archives are not exported by this mechanism.

See [Validation evidence](interactive-terminals-validation.md) for real-worker
scenarios, simulated coverage, failed attempts and qualification limits.

When a record uses an explicit guest path policy or expanded file budget,
[codec v9](guest-files.md#recovery-and-upgrades) supersedes its earlier envelope
and additionally requires `guest_files: 1`. Other feature capabilities and
retention rules still apply.
