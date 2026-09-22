# Long-running commands and background launch

SmolBox supports finite foreground command timeouts up to 24 hours and explicit
background launch on managed persistent image machines. Both require the qualified
smolvm 1.17.0 runtime. Background launch confirms a process was started; it is not
process supervision, readiness, or the eventual exit status.

## Foreground deadlines

Use foreground execution for builds, dependency installation and finite tasks
whose output and exit code you need. A host must approve the exact profile in its
worker catalog. For a command allowed to take 30 minutes:

```elixir
{:ok, command} = SmolBox.Command.new(["npm", "ci"], timeout_secs: 1800)
{:ok, profile} = SmolBox.Profile.new("build-30m-v1",
  execution_ms: 1_860_000,
  storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768
)
```

The disk settings are examples; use the verified allocation floors of your own
prepared artifact. Register the new profile with the worker. A persistent machine
has an immutable profile, so an existing machine created with a shorter profile
cannot silently acquire this budget. Create a machine under the approved longer
profile when needed.

Configure that worker's client with `operation_timeout_ms: 1_860_000` as well.
Defaults remain 30 seconds for the command, profile execution stage, and client
operation. Increasing only the command timeout is insufficient.

| Budget | Meaning |
|---|---|
| `Command.timeout_secs` | Requested guest foreground timeout, 1–86,400 whole seconds |
| `Profile.execution_ms` | Absolute controller observation budget from first dispatch intent, 1000–86,460,000 ms |
| `Worker.operation_timeout_ms` | Total client request budget, including preflight, connection, transfer and callbacks; 1–86,460,000 ms |
| `Worker.receive_timeout_ms` | Receive-idle budget for ordinary operations; extended exec uses its remaining operation budget so a quiet long command is observable |
| `SmolBox.await/3` timeout | Caller wait only, 0–900,000 ms; repeat observation for longer work |

The managed observer uses the earlier of its absolute stage deadline and the
worker operation deadline. Give observation budgets headroom beyond the guest
timeout if you need to receive the timeout result. The additional minute above
24 hours is an observation allowance, not extra guest execution time. These are
SmolBox policy bounds, not a claim that upstream has a 24-hour limit.

Preparation, collection and cleanup retain their independent five-minute maximum
budgets. Connection/pool budgets and lease limits are unchanged. The controller
renews leases while observing long work; a lease does not fence a worker request.

Long exec preflight and dispatch share one operation deadline. For foreground
commands above 300 seconds, the receive-idle timeout is scoped to that operation's
remaining deadline. No global Req/Finch defaults change. A deliberately shorter
operation deadline can still end observation before the guest exits.

Buffered and streaming foreground execution both support extended timeouts.
Streaming stdin remains unsupported; use buffered exec or input files. Output
limits still apply, regardless of how long a command runs. Losing the connection,
exceeding output limits or expiring a caller wait never proves guest termination.

## Launch a background service

Use background launch for a server or ongoing agent on a retained machine:

```elixir
{:ok, command} = SmolBox.Command.new(
  ["python", "-m", "http.server", "8000", "--bind", "0.0.0.0",
   "--directory", "/workspace"],
  background: true
)
{:ok, spec} = SmolBox.ExecutionSpec.new(
  scope: scope, id: "http-launch-001", artifact: artifact,
  profile: profile, command: command
)
{:ok, execution} = SmolBox.Machines.submit(runtime, computer, spec)
{:ok, %{state: :launched, result: %SmolBox.LaunchResult{pid: pid}}} =
  SmolBox.await(runtime, execution, 60_000)
```

`computer` is an owned running machine with a matching artifact/profile and,
for host HTTP access, a port mapping to guest port 8000. Observe readiness with a
separate request or command; launching a process does not prove it opened a port.

The low-level `Client.exec/4` also returns `%SmolBox.LaunchResult{}` for background
commands. Low-level callers supply ownership, lifetime and concurrency management.
Background launch requires a non-checkpoint image machine. The client verifies
version and image support before exec. `Client.exec_stream/4` and disposable
`SmolBox.submit/2` reject background commands before worker mutation.

`background: true` gives the command `timeout_secs: nil`. A non-nil timeout or
stdin is rejected: upstream's background path ignores these inputs. The managed
profile and client deadline bound observation of the launch request; they do not
limit the background process's lifetime. Explicit argv, environment, working
directory and image user options remain supported.

Upstream returns launch success as exit code zero and `pid=NUMBER` in stdout.
SmolBox strictly decodes that acknowledgment only for background requests. It does
not expose zero as the process's final exit code, or mistake foreground text that
looks like a PID for a launch result. Malformed or truncated acknowledgment is
uncertain launch evidence, even if the response reports zero.

The PID is upstream guest-side launch evidence and may belong to a different PID
namespace than the application. It is not a globally unique or durable process
identifier. It can be reused and cannot authorize adoption or automatic killing.
No per-process status, readiness, final output, final exit code or restart guarantee
is provided. Background standard streams are discarded by the qualified upstream
path; applications should deliberately write logs to files if required.

## Concurrency, cancellation and recovery

One command or launch operation can own a machine's command slot across controllers
sharing a store. Input staging occurs before launch within that slot. Background
output manifests are rejected because launch completion cannot establish final
file contents. After launch, read application files explicitly with awareness that
the running service may still be changing them.

A confirmed launch becomes terminal `state: :launched`, with `evidence: :launched`
and `collection: :complete` (there are no declared outputs). Cleanup releases the
command slot, retaining the machine and its numerical and port reservations.
Outcome observation can precede slot release. Observe `active_execution: nil`
before submitting another command. The slot serializes API operations, not all
guest activity: launched processes can overlap later commands and file operations.

Duplicate scoped launch intent returns the same execution, including after machine
deletion. Different intent under the same ID conflicts. Launch intent is persisted
before dispatch, and confirmed launch evidence survives controller restart with a
durable store. Recovery never turns retained PID evidence into a liveness claim.

If dispatch may have happened but its result was lost, the execution remains
unknown and retains the active slot. Subsequent commands and stop/delete intent
are blocked. No automatic launch replay occurs. Use the existing explicit
[quiescent resolution procedure](persistent-machines.md#cancellation-and-uncertain-outcomes):
fence/drain old controllers and in-flight worker requests, then stop the verified
owned machine or independently verify deletion before resolving the stored intent.
An observed stop or expired store lease alone does not fence an earlier request.
Unknown launch history remains unknown after resolution; no PID is invented.

Cancellation before dispatch prevents launch when the controller observes it
before committing dispatch. If staging or dispatch has become uncertain, existing
conservative recovery rules apply. During launch, cancellation can end observation
without stopping a process. After confirmed launch, cancellation records intent
but does not terminate the process or change the launch result. There is no safe
PID-based cancellation API in this release.

Stop and delete reject an active launch operation. After confirmed launch and slot
release, explicit stop/delete follow the usual machine lifecycle; they affect the
whole machine, including background processes. Machine stop/start preserves files,
not the launched service. Launch it again deliberately with a new execution ID.
Retained launch records describe historical evidence and never automatically
restart a service. Controller restart alone does not stop the machine or service.

## Persistence and upgrades

Extended execution requires store capability `extended_execution: 1` in addition
to the existing capabilities needed by the operation. The memory adapter and
PostgreSQL example implement it. Memory mode is not durable across BEAM restart.

Codec v6 is used for background execution records and records whose approved
profile execution budget exceeds 300,000 ms, including managed-machine records
with that profile. Ordinary foreground records retain their previous v2/v3/v5
wire shapes and fingerprints. Exact older command records gain `background: false`
on read; old envelopes cannot carry background fields or extended budgets.

Upgrade all controllers, adapters and readers sharing the worker/store authority
together before enabling this feature. Old controllers cannot read v6 or understand
`:launched`, and cannot safely coordinate these launches. Disabling new background
submissions does not make existing v6 history readable by older controllers.
Rollback requires a reviewed identity-preserving conversion or continued access
through the upgraded authority. Never discard undecodable history or treat it as
absence. Back up encrypted records and their keys before upgrading.

The PostgreSQL example uses existing encrypted payload and state columns; this
feature adds no SQL table or column migration. All prior migrations, including
managed port ownership, remain required. The adapter capability declares support
for the new codec and launch-state semantics, not a different retention policy.

## Runnable acceptance examples

The durable host's `scripts/persistent_http.exs prepare` and `resume` phases use
this API. Follow the environment and PostgreSQL setup in the durable host README
and the [port-mapping example](port-mappings.md#runnable-http-acceptance-example).
Use a fresh execution ID and partition for each run. The example checks readiness
in a subsequent command, recovers the persisted launch in a second BEAM, reuses
the same running service, explicitly launches a new service after VM stop/start,
then verifies deletion, reservation release and retained deduplication history.

For a runnable long foreground example, use the same durable-host environment
with a fresh ID/partition and run `MIX_ENV=test mix run scripts/long_foreground.exs`.
It executes a quiet 305-second command and verifies output, exit and disposable cleanup.

The opt-in `test/extended_runtime` suite runs real 305-second quiet buffered and
managed streaming commands. Configure the runtime URL/socket and approved Python
artifact, then run:

```sh
mix test test/extended_runtime --include runtime --warnings-as-errors
```

Allow more than ten minutes for this suite and enough worker lifetime for the
whole run. It uses dedicated machines, 2 GiB storage/overlay requests, and requires
a qualified artifact plus working `resize2fs`. It checks caller-await expiry and
separately proves a client observation timeout can leave guest work running.

Inside the existing disposable Linux lab, `bash scripts/lab/long-running-exec.sh`
runs the extended suite and both durable HTTP phases. Set `SMOLBOX_EXEC_ATTEMPT`
to a fresh lowercase alphanumeric label for each run. The script explicitly raises
only the worker lifetime from 300 to 900 seconds and restores it on exit. CPU,
memory, task, disk and namespace restrictions remain intact, as does the physical
host's 45-minute outer-VM deadline. The longer worker deadline is necessary to
observe workloads beyond five minutes; it is not a production isolation claim.

See the [validation report](long-running-exec-validation.md) for measured Linux/macOS
long execution, durable background HTTP acceptance, checks and remaining limits.
