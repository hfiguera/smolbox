# Troubleshooting

Start with the returned `SmolBox.Error` and the original execution identity.
Errors expose a category, operation, dispatch evidence, and sometimes a known
exit code. They intentionally omit raw response bodies and command data.

## An outcome is not a success flag

For an existing `runtime` and `{scope, id}` handle, inspect all three outcomes:

```elixir
case SmolBox.fetch(runtime, scope, id) do
  {:ok, %{state: :unknown} = record} ->
    {:needs_investigation, record.evidence, record.cleanup}

  {:ok, %{result: %SmolBox.Result{} = result} = record} ->
    {:observed_exit, result.exit_code, record.collection, record.cleanup}

  {:ok, record} ->
    {:pending_or_not_dispatched, record.state, record.last_error}

  {:error, %SmolBox.Error{} = error} ->
    {:inspection_failed, error.category, error.operation}
end
```

`:completed` means a command exit was observed and declared outputs were
collected; the exit code may be nonzero. `:collection_failed` preserves the
command result while recording unavailable outputs. `cleanup: :complete` and
`reservation: nil` establish completed cleanup and released admission capacity.
`await/3` can return before these last two fields are set.

## Common problems

| Symptom | What to check and do |
|---|---|
| Git dependency cannot be fetched | Verify repository access and the requested tag. The candidate is not on Hex; use an accessible checkout or the documented Git dependency. |
| `Worker.new/3` returns `:validation` | Remote endpoints need HTTPS, a nonempty bearer token, and valid certificate configuration. Local HTTP needs explicit loopback permission or a Unix socket. Base URLs cannot contain an API path. |
| `Directory.new/1` returns `:validation` | Supply an absolute existing directory with mode `0700`, owned and controlled by the host. Creating the adapter does not create the directory. |
| Runtime startup rejects the memory store | Set `mode: :ephemeral` for a deliberate local demo. Durable mode requires a conforming durable adapter and never falls back to memory. |
| `ExecutionSpec.new/1` returns `:validation` | Compare required fields and constructor limits. Artifact and manifest maps use string keys. `command.timeout_secs * 1000` must not exceed `profile.execution_ms`. |
| `submit/2` returns `:unsupported_capability` | The exact profile and artifact identity must appear in a configured worker's catalogs. Profile allocations must meet its `allocation_floor`. Default 1/1 GiB profile disks do not meet the reference 20/10 GiB floor. |
| An accepted execution stays queued | Inspect `SmolBox.workers/1` for health, version, readiness, and drain status. Check available reservations, `max_active`, and the queue deadline. Acceptance does not mean the worker has started the command. |
| `:admission_exhausted` | Check queued work and store limits. The memory store retains completed identities; its record/byte limits can fill even after guest cleanup. Do not discard a store that still owns work to make room. |
| `:identity_conflict` | The same scoped ID was used with different semantic inputs, or an immutable artifact receipt conflicts. Recover the original specification. A deliberate changed execution needs a new authorized ID. |
| `await/3` returns `:expired` | Only this caller's waiting budget expired. Fetch or await the same handle again. Request cancellation explicitly if that is your intention. |
| `exec_stream/4` rejects stdin | SmolVM 1.14.1 ignores streaming stdin. Use `exec/4` for bounded UTF-8 stdin or stage a file. The managed runtime selects buffered exec when stdin is present. |
| Output is incomplete or `:output_limit` is returned | Check both the worker response-byte limit and decoded output limit. Inspect `truncated`, `evidence`, and any known exit code. Capture limits do not stop the guest or justify replay. |
| Collected output is missing | Check `collection`, `artifacts`, and `last_error`, then the artifact adapter. Restoring storage and resubmitting the same ID does not rerun the command or recreate deleted guest files. |
| Cleanup or reservations remain pending | Check ownership evidence, worker availability, retention, and cleanup attempts. An unknown outcome normally retains its VM until the execution deadline plus `retention_ms` (24 hours by default). |

## Recover without repeating uncertain work

`reconcile/3` schedules another observation of existing evidence; it does not run
the command again or reset exhausted deadlines. A stored `:unknown` outcome can
remain unknown even after the VM is stopped and deleted. SmolVM 1.14.1 provides
no durable command receipt or request fence from which to reconstruct that result.

After an ambiguous submission error, keep the original spec and identity. Once
the store is available, inspecting or resubmitting that same spec lets atomic
acceptance recognize an existing request. Choosing a new ID can create a second
execution; a transport or store timeout is not proof the first was rejected.

After a controller restart, use the same durable store, keys, worker IDs and
namespace. Memory mode cannot restore the original records. Follow
[Persistence and recovery](recovery.md) for unavailable or corrupted stores and
[Deployment boundaries](security.md#upgrades-and-operator-recovery) for operator
recovery after exhausted cleanup. Do not delete machines based only on a name
prefix, use file downloads as passive recovery probes, or treat telemetry events
as authoritative state.

## Useful reports

For an existing named runtime:

```elixir
{:ok, workers} = SmolBox.workers(runtime)
{:ok, notifications} = SmolBox.telemetry_stats(runtime)
{:ok, page} = SmolBox.audit_worker(runtime, worker_id, limit: 20)
```

These are host/operator APIs. Authorize access before exposing them. Full records
returned by `fetch/3` can contain source arguments, stdin, environment and results;
share redacted summaries when reporting an issue. Include the SmolBox/SmolVM and
Elixir/OTP versions, OS/architecture, error category/operation/evidence, execution
state, collection and cleanup status, and whether the worker/store was restarted.
