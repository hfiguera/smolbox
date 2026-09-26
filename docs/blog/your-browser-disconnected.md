You start a command in a browser terminal. Output scrolls past. Then the connection drops.

Do you open another terminal and run it again?

If the first command only prints the time, that might be harmless. If it installs
packages, writes a file or starts a service, a second attempt can make a confusing
situation worse. The first command might still be doing its job.

**A disconnected browser tells you that you lost a connection. It does not tell
you how the command ended.**

In our [workspace article][workspace], we separated the browser, command and
machine lifetimes. Here we will follow one terminal session through a disconnect,
look at the evidence that survives, and decide when another command is safe.
The API examples use SmolBox 0.2.1 with smolvm 1.19.0.

## Which connection did you lose?

A browser terminal usually has more than one connection behind it. The browser
talks to your application. Your application owns a connection to the worker.
Inside the VM, a program reads and writes through a pseudoterminal, or PTY.

A failure between the browser and your application does not necessarily close
the worker connection. A controller crash or a lost worker socket is a different
failure. Start by finding that boundary.

A terminal session can outlive its browser view, but only while something else
still owns the live worker connection.

<figure class="disconnect-figure" id="disconnect-lab" aria-labelledby="disconnect-caption">
  <div class="disconnect-controls" hidden>
    <div class="disconnect-cases" role="group" aria-label="Terminal scenario">
      <button type="button" data-disconnect-case="browser" aria-pressed="true">Browser disconnects</button>
      <button type="button" data-disconnect-case="worker" aria-pressed="false">Worker connection drops</button>
      <button type="button" data-disconnect-case="exit" aria-pressed="false">Shell exits</button>
    </div>
  </div>
  <div class="disconnect-stage" data-phase="lost">
    <p class="disconnect-headline">The connection ended. The outcome is unknown.</p>
    <p class="disconnect-detail">Without a trustworthy exit notification, we cannot say how the program finished.</p>
    <div class="disconnect-route" aria-hidden="true">
      <div class="disconnect-node"><span>Browser</span><strong class="disconnect-browser">Disconnected</strong><small>Your view</small></div>
      <div class="disconnect-link browser-link"><svg viewBox="0 0 100 30"><path class="disconnect-track" d="M0 15 H100"/><path class="disconnect-packet" d="M0 15 H100"/></svg><span class="browser-link-label">No stream</span></div>
      <div class="disconnect-node controller-node"><span>Controller</span><strong class="disconnect-controller">Keeps the record</strong><small>Session owner</small></div>
      <div class="disconnect-link worker-link"><svg viewBox="0 0 100 30"><path class="disconnect-track" d="M0 15 H100"/><path class="disconnect-packet" d="M0 15 H100"/></svg><span class="worker-link-label">No exit received</span></div>
      <div class="disconnect-node guest-node"><span>Guest process</span><strong class="disconnect-guest">Unknown</strong><small>Inside the retained VM</small></div>
    </div>
    <div class="disconnect-record"><span>Execution record</span><code class="disconnect-evidence">outcome: unknown</code></div>
    <p class="disconnect-explanation">Keep the original identity. A new session cannot tell you what happened to the old one.</p>
  </div>
  <div class="disconnect-controls disconnect-playback" hidden>
    <button type="button" class="disconnect-play">Play scenario</button>
    <button type="button" class="disconnect-next">Next step</button>
    <span class="disconnect-step" role="status" aria-live="polite" aria-atomic="true"></span>
  </div>
  <figcaption id="disconnect-caption">Choose where the connection ends. The browser scenario assumes the application's terminal owner and worker connection survive. This is an explanatory animation, not a live terminal or a timing measurement. A returned stream is not an exit result.</figcaption>
</figure>

The animation's browser case uses a pattern from the community workspace:
a supervised process owns the SmolBox terminal handle, separately from the
LiveView process. When that LiveView process goes away, the owner allows a
30 second window for a new browser consumer to return.

That window belongs to the **example application**. It is not a SmolBox promise
that a terminal can always reconnect. It only helps while that owner and its
existing worker connection remain alive. Session deadlines, idle limits and
output limits still apply. It does not survive a controller restart.

The [workspace implementation][session-owner] is useful to read alongside its
[tests][session-tests]. It keeps output bounded and can redeliver one pending
output frame. That is different from replaying input: a repeated display frame
might be annoying; a repeated command can change the machine twice. A production
terminal should handle its own display reconciliation too.

## Keep the owner separate from the view

In SmolBox, opening a managed terminal returns a durable execution identity.
Attaching binds the calling Elixir process to the live session:

```elixir
{:ok, terminal_spec} =
  SmolBox.Terminal.Spec.new(
    program: "/bin/sh",
    session_ms: 300_000,
    idle_ms: 60_000
  )

{:ok, spec} =
  SmolBox.ExecutionSpec.new(
    scope: scope,
    id: "shell-001",
    artifact: approved_artifact,
    profile: approved_profile,
    command: terminal_spec
  )

{:ok, execution} = SmolBox.Terminal.open(runtime, machine, spec)
{:ok, terminal} = SmolBox.Terminal.attach(runtime, execution, 30_000)
```

This excerpt assumes an owned, running managed image machine and a profile that
allows the session's time and output budgets. The [terminal guide][terminals]
provides the full setup and limits. There is no implicit working directory
option for a terminal; send `cd` to the shell when you need it.

The process that calls `attach/3` owns input, resize, close and output consumption.
Route authorized browser events through that process. Do not hand the terminal
handle to a new LiveView and expect it to become the owner.

Also, `attach` is not a guest reconnect operation. It binds a consumer to a live
connection on the runtime that already owns it. Another controller sharing the
database can inspect or cancel the execution, but cannot take over its stream.

This gives the UI a useful vocabulary: “Reconnecting to your session” while the
application still has it, and “Connection lost; outcome unknown” when it does not.
Showing “Command failed” merely because a socket closed would claim more than
we know.

## Wait for an exit, not just silence

A terminal produces chunks of bytes and, when available, a final outcome. One
input line can produce several output events, and one output event can contain
more than one line.

These are the cases an event loop needs to distinguish:

```elixir
case SmolBox.Terminal.next(terminal, 5_000) do
  {:ok, {:output, bytes}} ->
    {:render, bytes}

  {:ok, {:closed, {:ok, %SmolBox.Terminal.Result{exit_code: code}}}} ->
    {:observed_exit, code}

  {:ok, {:closed, {:error, error}}} ->
    {:uncertain, error}

  {:error, %SmolBox.Error{category: :expired}} ->
    :nothing_received_yet

  {:error, error} ->
    {:inspect_record, error}
end
```

This is one iteration, not a complete stream consumer. Keep pulling output in
a supervised process; do not block a LiveView callback with a five second wait.
Render the bytes through a terminal renderer with your application's control
sequence policy, rather than inserting them as HTML.

The read timeout above ends **that call's wait**. It does not cancel the command.
The session and idle deadlines are separate: when those expire, observation
closes and the outcome can be uncertain.

When a trustworthy exit arrives, fetch or await the durable result. Live delivery
can precede the store update:

```elixir
{:ok, record} = SmolBox.await(runtime, execution, 30_000)
```

An observed terminal exit is stored as `state: :completed`, with `evidence: :exited`
and a `Terminal.Result`. Check the exit code separately. In the demo below, the
shell deliberately exits with code 7: its outcome is known, even though the
program did not report success. Upstream's synthetic statuses `-1`, `124` and
`130` remain uncertain because the wire cannot reliably distinguish them from
an application's identical exit code.

Before submitting another managed command, also wait for the machine's
`active_execution` to become `nil`. Receiving an exit event and releasing the
command slot are separate steps. The retained machine and its files remain.
An exit from the shell does not prove that every descendant or background service
has stopped.

## Close, cancel and Ctrl-C mean different things

A “Stop” button is easy to draw. Its promise needs more care.

| Action | What it actually requests |
| --- | --- |
| `Terminal.input(terminal, <<3>>)` | Sends Ctrl-C as terminal input. The guest's terminal mode and program determine its effect. |
| `Terminal.close(terminal)` | Closes local terminal observation. A socket close alone does not prove guest termination. |
| `SmolBox.cancel(runtime, scope, id)` | Records cancellation intent. Before dispatch it can prevent opening; after possible dispatch it closes observation and preserves uncertainty. |
| A trustworthy exit notification | Supplies evidence that the terminal program exited with the reported status. |

smolvm attempts to kill its direct PTY child when the agent connection ends.
That still leaves two questions: did this controller observe a trustworthy exit,
and did any detached descendants survive? Neither can be answered from the
browser's disconnected banner.

The existing live terminal test makes the second question concrete. It launches
a detached child that writes a heartbeat, abruptly loses the terminal connection,
and then checks that the heartbeat still advances. This is why the article's
answer cannot simply be “the process stops when the socket closes.”

## An unknown outcome is a reason to inspect

After a controller restart, the durable store recovers the execution's identity
and saved evidence. It does not recover a live terminal socket or an input/output
transcript. A potentially dispatched session without a saved exit becomes
`unknown`; a previously saved exit stays known.

Keep the original scope and execution ID when inspecting that result:

```elixir
{:ok, record} = SmolBox.fetch(runtime, scope, "shell-001")
```

Submitting the same immutable specification with that identity returns the same
execution. It does not open a replacement shell or send the old keystrokes again.
A fresh ID would describe new work, not a retry that somehow knows the first
command's outcome.

While an unresolved session may still execute, SmolBox keeps the machine's
command slot occupied. Subsequent managed commands and ordinary stop/delete
requests are blocked. That can feel inconvenient in a demo. It prevents a new
command from racing work whose outcome is still unknown.

Resolution is an operator action: drain old controllers and requests already
sent to the worker, verify the recorded machine ownership, establish a stopped
machine or verified deletion, then resolve the inspected durable record. A store
lease expiring, or one observation of a stopped VM, does not prove that an older
request can no longer arrive.

Follow the [recovery procedure][recovery] for the ordering and evidence required.
If your procedure restarts the dedicated worker, its preliminary verified stop
protects supported persistent disks; it does not itself establish that requests
have drained. Do not delete the record or set `quiesced: true` just to enable a
button. Resolution frees the slot once safe; it does not turn the old unknown
outcome into a successful result.

## Try an observed exit first

The repository includes a small terminal demo that exercises the complete known
outcome. Use a dedicated smolvm 1.19.0 worker and follow the
[durable host setup at v0.2.1][durable]. It requires PostgreSQL with the example
migrations applied, stable private keys, and an approved native Python image.

From `examples/durable_host` in a checkout of tag `v0.2.1`, run:

```sh
export SMOLBOX_RUNTIME_VERSION=1.19.0
export SMOLBOX_STORE_PARTITION=terminal-blog-demo
export SMOLBOX_EXECUTION_ID=terminal-blog-exit-1
mix run scripts/terminal.exs run
```

The demo writes a file, resizes the terminal, observes exit code 7, reads the file
through a separate command, then explicitly deletes its machine and verifies
reservation release. Choose a fresh ID for a new completed demonstration;
deleted identities keep their history.

For a human operated shell, choose another ID and use the `shell` phase:

```sh
export SMOLBOX_EXECUTION_ID=terminal-blog-shell-1
mix run scripts/terminal.exs shell
```

Type `exit 7` to produce an observed shell exit. This phase retains the machine.
After confirmed slot release, remove it explicitly using the same ID and partition:

```sh
mix run scripts/terminal.exs delete
```

The console also accepts `:close`, but that deliberately creates a different
situation: observation closes without proving how the guest ended. Expect to
inspect the durable outcome and, if uncertain, follow recovery before deleting
or opening more work. Preserve the original IDs, database and keys. The demo's
`interrupt` and `recover` phases are documented in the [terminal guide][terminals]
for a controlled controller failure exercise.

For this article, we reran the three live terminal cases and the durable `run`
demo on macOS Apple Silicon with SmolBox 0.2.1 and smolvm 1.19.0. The
[recorded checks](../../media/your-browser-disconnected/validation.json)
separate that live evidence from the simulated browser owner tests. The interactive
figure illustrates those boundaries; it is not a claim that every disconnected
process survives, or that browser reconnection always succeeds.

## Give the next action a reason

A useful terminal UI can say what it knows: the view disconnected, the existing
session is available, an exit was observed, or the result needs investigation.
Each statement leads to a different next action.

That distinction matters for people and for agents. Before either presses “Run
again,” preserve the identity and ask what evidence makes that next execution
safe. A lost connection should not quietly become a second command.

[workspace]: ../build-a-persistent-workspace/
[session-owner]: https://github.com/hfiguera/smolbox/blob/v0.2.1/examples/community_workspace/lib/workspace/terminal_session.ex
[session-tests]: https://github.com/hfiguera/smolbox/blob/v0.2.1/examples/community_workspace/test/workspace/terminal_session_test.exs
[terminals]: https://hexdocs.pm/smolbox/0.2.1/interactive-terminals.html
[recovery]: https://hexdocs.pm/smolbox/0.2.1/persistent-machines.html#cancellation-and-uncertain-outcomes
[durable]: https://github.com/hfiguera/smolbox/tree/v0.2.1/examples/durable_host
