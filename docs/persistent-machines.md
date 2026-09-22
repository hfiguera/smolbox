# Managed persistent machines

`SmolBox.Machines` manages a machine independently of its commands. Its files
remain available across commands, controller restarts with durable storage, and
successful stop/start. Machines are retained until explicitly deleted. Existing
`SmolBox.submit/2` executions remain disposable.

This feature requires a store advertising `managed_machines: 1`. Both the memory
adapter and PostgreSQL example implement it. Memory mode remains ephemeral: a
controller restart can reconnect only while that memory store survives; a BEAM
restart loses it. Use the durable adapter for application restart recovery.

## Create, start, and reuse

Use the runtime configuration from [Host integration](host-integration.md), with
an approved artifact and profile. The host authorizes every scope and operation;
handles are identifiers, not authorization tokens. Ownership still depends on
recorded creation evidence and exclusive namespace control: upstream timestamps
have second precision and are not immutable ownership tokens.

```elixir
alias SmolBox.{Command, ExecutionSpec, ManagedMachineSpec, Machines}

{:ok, spec} = ManagedMachineSpec.new(
  scope: "my-app",
  id: "workspace-001",
  artifact: python_artifact,
  profile: profile
)
{:ok, computer} = Machines.create(MyApp.Sandboxes, spec)
{:ok, %{state: :created} = machine} = Machines.await(MyApp.Sandboxes, computer, 90_000)

{:ok, _accepted} = Machines.start(MyApp.Sandboxes, computer, machine.version)
{:ok, %{state: :running}} = Machines.await(MyApp.Sandboxes, computer, 90_000)

for {id, source} <- [
  {"write-001", "from pathlib import Path; Path('/workspace/value').write_text('42')"},
  {"read-001", "from pathlib import Path; print(Path('/workspace/value').read_text())"}
] do
  {:ok, command} = Command.new(["python", "-c", source], timeout_secs: 5)
  {:ok, execution_spec} = ExecutionSpec.new(
    scope: "my-app", id: id, artifact: python_artifact,
    profile: profile, command: command
  )
  {:ok, execution} = Machines.submit(MyApp.Sandboxes, computer, execution_spec)
  {:ok, %{state: :completed, result: result}} =
    SmolBox.await(MyApp.Sandboxes, execution, 90_000)
  IO.write(result.stdout)
  # Outcome observation can precede release of the command slot.
  {:ok, %{state: :running, active_execution: nil}} =
    Machines.await(MyApp.Sandboxes, computer, 90_000)
end
```

The matches illustrate success; production callers must handle nonzero exits,
unknown outcomes, collection failures, admission conflicts, and unavailable stores.
An execution must match the machine's scope, artifact, and exact profile. Input
and output manifests work as for disposable executions. Their staging and
collection remain inside the machine's exclusive command slot. Guest processes
started in the background by a command are not separate managed executions.

## Lifecycle and identity

| Operation | Contract |
|---|---|
| `create(runtime, spec)` | Persist immutable creation intent; identical scoped specs return the original handle, including after deletion; changed specs conflict |
| `list(runtime, scope, cursor: cursor, limit: 20)` | Return `{:ok, records, next_cursor}`; includes deleted identities; limit is 1–100 |
| `inspect(runtime, handle)` | Read durable management evidence without contacting the worker |
| `await(runtime, handle, timeout)` | Wait for idle or blocked state; inspect the returned state; does not cancel anything |
| `start/3`, `stop/3`, `delete/3` | Accept intent with the inspected record version, then return the accepted machine record |
| `submit(runtime, handle, execution_spec)` | Atomically accept one command; return its normal execution handle |
| `reconcile(runtime, handle)` | Schedule observation; uncertain mutations are not replayed |
| `resolve(runtime, handle, version, options)` | Explicit operator recovery after quiescence, described below |

The version argument prevents requests based on old observations from reversing
newer intent. Retrying the most recent identical action with its original version
returns the current record. After another lifecycle request supersedes it, the old
version fails with `:stale_version`. Refetching and sending a new version is a new
intent, not a retry. A pending create without a worker assignment can be deleted
without creating a VM. Once assigned, creation uncertainty requires resolution.

Commands have separate scoped identities. Duplicate submission returns the
original execution, even after later commands or machine deletion. Changed command
specifications or a different machine under that execution ID conflict. Commands
share the execution ID namespace with disposable submissions, but their
fingerprints include their managed-machine identity.

Only one managed command is active at a time across controllers sharing a store.
Another command returns `:admission_exhausted`; there is no per-machine command
queue in this release. Stop/delete also reject an active command. Start and file
operations are never used as recovery probes: upstream can start stopped machines
as a side effect of file transfer or exec.

## Stop, delete, and capacity

```elixir
{:ok, machine} = Machines.inspect(MyApp.Sandboxes, computer)
{:ok, _accepted} = Machines.stop(MyApp.Sandboxes, computer, machine.version)
{:ok, %{state: :stopped} = stopped} = Machines.await(MyApp.Sandboxes, computer, 90_000)

{:ok, _accepted} = Machines.start(MyApp.Sandboxes, computer, stopped.version)
{:ok, %{state: :running} = running} = Machines.await(MyApp.Sandboxes, computer, 90_000)

{:ok, _accepted} = Machines.delete(MyApp.Sandboxes, computer, running.version)
{:ok, %{state: :deleted, reservation: nil}} = Machines.await(MyApp.Sandboxes, computer, 90_000)
```

Stop preserves disks. Explicit deletion discards them and verifies absence before
releasing reservations. A successful DELETE response alone is insufficient.

The machine owns its full slot, CPU, memory, and disk reservation, including while
stopped, unknown, missing, or inaccessible. Commands do not reserve these resources
again or release them on completion. Both kinds of machine share worker capacity
accounting. Keeping stopped resources reserved is conservative and avoids
oversubscribing later starts; it is not a measurement of actual host utilization.

Machine retention is independent of execution evidence retention. There is no
idle expiry, automatic shutdown, machine TTL, or deletion triggered by a command's
`retention_ms`. Completed command identities and deleted machine identities remain
stored for deduplication. Hosts must plan storage limits and archival without
silently erasing identities; the bounded memory adapter eventually rejects new
records when full.

## Cancellation and uncertain outcomes

`SmolBox.cancel/3` on a managed command records cancellation intent. Before dispatch,
it can prevent execution. After dispatch it ends managed observation and preserves
an unknown outcome unless an exit was already observed. It does **not** delete or
automatically stop the persistent machine. The guest may still be running.

Commands with unknown outcomes retain the exclusive command slot. Interrupted
preparation and failed collection conservatively block reuse too, since late file
operations can modify or restart the guest. A known exit survives collection failure.
An observed stop does not prove that an older exec/upload/download request cannot
arrive later. Store claims fence store writes, not worker HTTP requests.

For blocked machines:

1. Inspect the machine and its active execution. Preserve the original identities
   and unknown outcomes; do not submit a replacement attempt automatically.
2. Quiesce old controllers and drain or fence their outstanding worker requests.
   The host/operator must establish this boundary; SmolBox cannot establish it
   from a worker status response.
3. Verify ownership and stop the actual machine using operator tooling. Refetch
   the managed record and call:

   ```elixir
   {:ok, blocked} = Machines.inspect(MyApp.Sandboxes, computer)
   {:ok, %{state: :stopped}} = Machines.resolve(
     MyApp.Sandboxes, computer, blocked.version, quiesced: true
   )
   ```

This asserts operator quiescence, verifies the recorded incarnation is stopped
(or still in its original created state), clears the exclusive slot, and preserves
the command's unknown outcome. Start the machine explicitly before more commands.
A lifecycle response lost after dispatch also requires this resolution rather
than automatically replaying start/stop.

If the machine was lost, or an unverified creation was removed by the operator,
use `quiesced: true, disposition: :deleted` after cleanup. SmolBox verifies a 404
and records deletion without sending another mutation. This explicit procedure
can resolve missing creation evidence. An ordinary 404 cannot: an old create
request might still be in flight. Neither inventory nor a matching name authorizes
adoption. A worker/store outage is an error, never absence.

Machines are local to their assigned worker. Durable records recover management;
they do not back up disks, restore lost files, migrate guests, or transparently
replace missing machines. Maintain worker storage and backups separately.

## Store contract and upgrades

The optional `c:SmolBox.Store.machine/3` transaction callback adds:

- `:accept`, `:fetch`, `:list`, and `:due` for durable identity and bounded scans;
- `:claim`, `:claim_version`, `:write`, and `:reserve` for ownership, CAS, intent,
  and reservations shared with disposable machines;
- `:request` for versioned lifecycle intent;
- `:submit`, `:finish`, and `:resolve` for atomic machine/execution coordination.

Callback argument lists are:

| Operation | Arguments |
|---|---|
| `:accept` | `[initial_machine, max_pending]` |
| `:fetch` | `[machine_key]` |
| `:list` | `[scope, id_cursor_or_nil, limit]` |
| `:due` | `[now_ms, due_cursor_or_nil, limit]` |
| `:claim` | `[machine_key, owner, now_ms, lease_ms]` |
| `:claim_version` | `[machine_key, expected_version, owner, now_ms, lease_ms]` |
| `:write` | `[machine_key, guard, keyword_changes, now_ms]` |
| `:reserve` | `[machine_key, guard, {worker_id, machine_name, capacity}, now_ms]` |
| `:request` | `[machine_key, action, expected_version, now_ms]` |
| `:submit` | `[machine_key, initial_execution, max_pending, now_ms]` |
| `:finish` | `[execution_key, execution_guard, now_ms]` |
| `:resolve` | `[machine_key, machine_guard, stopped_observation_or_absent, now_ms]` |

Keys are `{scope, id}`. Guards carry owner, claim generation, and record version.
Due cursors are `{next_due_at_ms, scope, id}`. Most calls return `{:ok, machine}`;
`:submit` and `:finish` return `{:ok, execution}`, while page calls return
`{:ok, records, next_cursor}`. Failures return `{:error, SmolBox.Error.t()}`.
The resolution absence marker is `:absent`, supplied only after the runtime has
verified absence following operator quiescence. Storage itself sends no worker I/O.

The bundled adapters implement these transactions. `MachineOps` supplies pure
checks; adapters must supply atomicity. Run the reusable
`test/support/store/machine_contract.ex` scenarios alongside the existing execution
store suite. Existing adapters without the optional capability retain disposable
support and reject the managed-machine API with `:unsupported_capability`.

Managed machines and their command records use codec envelope **v4**. Disposable
image/checkpoint records keep their previous v2/v3 byte shape; old records load with
an empty managed-machine reference. Older controllers cannot read v4 and cannot
account for retained reservations, even if they only run disposable work.

Before enabling this feature on shared workers:

1. Drain and stop **all** controllers sharing the worker/store authority. Back up
   records and preserve fingerprint/encryption keys.
2. Upgrade every reader and adapter. Apply the PostgreSQL example's
   `20260922000000_managed_persistent_machines` migration. It adds the machine
   table and execution association projection; existing payloads need no backfill.
3. Restart upgraded controllers, verify capability checks and existing disposable
   recovery, then run a small persistent-machine acceptance test.

The PostgreSQL example encrypts machine records with a separate authenticated
identity domain, validates stored projections, and serializes transactions on the
same partition lock as disposable reservations. Each physical worker still needs
one stable ID and one shared store authority. Independent stores cannot coordinate.

Rollback requires a reviewed migration preserving identities and evidence, or
separate upgraded workers/store authority. Disabling new creates is insufficient:
retained machines, commands, and deletion history remain. The SQL down migration
refuses to drop tables while these records exist.

## Runnable two-process demonstration

The durable host example includes `scripts/persistent_machine.exs`.
Configure the database and environment as in the durable host README, create a
private artifact directory, and apply migrations. Use a dedicated, approved
smolvm 1.16.1 worker with functioning `resize2fs`; this small demo requests 2 GiB
storage and 2 GiB overlay and requires an image qualified for those sizes.

From `examples/durable_host`:

```sh
MIX_ENV=test mix run scripts/persistent_machine.exs prepare
# The first BEAM has exited; keep the same keys, partition and execution ID.
MIX_ENV=test mix run scripts/persistent_machine.exs resume
```

The first process creates, starts, writes, and reads. The second reconnects, reads,
stops/starts, reads again, explicitly deletes, verifies absence, and checks zero
reserved resources. Output reports the machine name so both processes can be
compared. A failure retains evidence and may require the resolution procedure.

See [validation evidence](persistent-machines-validation.md) for the tested scope
and remaining qualification limits.
