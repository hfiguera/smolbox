# Durable worker draining

Drain a worker before maintenance to stop assigning new machines across every
controller sharing its store. The admission mode survives controller restarts.
Draining never stops or deletes a VM, releases a reservation or calls smolvm's
worker-wide `/drain` endpoint.

This feature requires a store advertising `worker_control: 1`. The PostgreSQL
example persists the mode in a new table; the memory adapter retains it only while
that store process lives. There is no fallback to a controller-local drain.

## Drain, inspect and resume

Given an existing runtime and configured worker ID:

```elixir
{:ok, before} = SmolBox.worker_maintenance(MyApp.Sandboxes, "worker-1")
{:ok, drained} =
  SmolBox.drain_worker(MyApp.Sandboxes, "worker-1", before.control.version)

{:ok, report} = SmolBox.worker_maintenance(MyApp.Sandboxes, "worker-1", limit: 20)
IO.inspect(report.control, label: "Shared admission mode")
IO.inspect(report.records, label: "Assignments needing attention")
IO.inspect(report.reserved, label: "Total reservations on this worker")
IO.inspect(report.assessment)

# Only after maintenance, host verification and deliberate operator authorization:
{:ok, resumed} =
  SmolBox.resume_worker(MyApp.Sandboxes, "worker-1", drained.version)
```

A successful resume permits new reservations only when health, policy and capacity
also allow them. A statically configured `draining: true` worker must be reconfigured
before resume. The host must authorize these operator APIs; worker IDs and control
versions are not credentials.

`drain_worker/2` remains a convenient `:ok`-returning operation that ensures the
worker is draining. Repeating it while already draining leaves the version alone.
Use `drain_worker/3` when you need a new revision, including while already draining,
to invalidate outstanding resume requests. Both versioned operations deduplicate
the last identical request. An older resume cannot undo an intervening state change.
A lost response does not imply failure: inspect the control or retry the exact
versioned request. Do not blindly replace the version with a newer one and resume.

## What admission stops

The store serializes draining with resource admission, so a task holding an old
controller snapshot cannot reserve a new machine after the drain commits.

| Operation | While draining |
| --- | --- |
| New disposable machine reservation | Blocked; accepted requests can wait, expire or use another eligible worker |
| New retained machine or checkpoint restore assignment | Blocked |
| New disk growth, branch, checkpoint capture or export helper admission | Blocked |
| Retry of an existing identity/history entry | Returns existing evidence; it does not create another resource |
| Work whose assignment or helper admission committed before draining | May continue, including later worker requests |
| Commands, PTYs, image pulls and start/stop on existing machines | Allowed under the usual ownership and lifecycle rules |
| Observation, cancellation, recovery and cleanup | Continue under the usual rules |

Draining does not revoke worker leases. Reconciliation must retain the ability to
observe and clean up existing work. New work on retained machines can prolong
maintenance indefinitely unless the host also pauses submissions for those machines.
Store fencing cannot retract HTTP already sent, and even an observed stop does not
prove that a delayed request cannot start a VM again.

## Read the maintenance report

`SmolBox.WorkerMaintenance` contains one store-consistent page across scopes:

- `control`: current admission mode, version, last request version and update time.
- `records`: redacted machine/execution identities, lifecycle state, operation,
  active command handle, execution evidence/cleanup state and accounted resources.
- `reserved`: the worker's full resource totals, including saved artifacts and
  branch backing, independent of page size.
- `next_cursor`: pass as `cursor:` to fetch the next page; nil ends that scan.
- `assessment`: `:blocked` when resources or assignments need attention, admission
  is active, or this is a continuation page.

A first page with no records, zero reservations and draining admission returns
`:operator_quiescence_required`. It never returns “safe to shut down.” It cannot
observe unmanaged VMs, every background process, outstanding worker requests or
activity from another store authority. Stored running/stopped state may be stale.

Deleted machine records that retain checkpoint files or branch backing still appear.
Completed clean execution history is omitted. Inspect the referenced machine or
execution for its detailed recovery history. The report contains no command text,
file contents or credentials. A store error is an error, never an empty inventory.

Each page is a new transaction. Concurrent cleanup or existing-machine activity
can change later pages; restart from a nil cursor for a fresh assessment.
`workers/1`, `worker_report/2` and `admission_report/2` also reflect current durable
admission mode. Store-control read failures make the reported worker unavailable;
health alone cannot authorize admission.

## Prepare for maintenance

1. Pause application submissions, including new work on retained machines, and
   establish a drain revision. Coordinate all mutating clients and store authorities.
2. Inspect every report page. Let admitted work finish or resolve it through the
   existing recovery procedures. Unknown commands are never replayed automatically.
3. Decide explicitly what to preserve. Stop retained machines through their managed
   API and verify ownership and final state. Preserve their disks and saved artifacts
   if the maintenance plan keeps them. Their records and disk reservations remain;
   a `:blocked` report is not an instruction to delete them merely to make it empty.
4. Establish operator quiescence: prevent additional mutations, deal with requests
   already sent, and verify the actual worker inventory and host processes. Empty
   store records or low CPU usage are insufficient. Follow the worker's shutdown
   and storage preservation requirements.
5. After maintenance, verify the pinned runtime, disks, owned machines and health.
   Inspect the latest control version and explicitly resume admission.

See [host integration](host-integration.md#upgrading-a-worker) and
[recovery](recovery.md) for ownership and disk-preservation constraints. Migration,
evacuation, automatic stopping and automatic shutdown are outside this feature.

## Adapter upgrade and rollback

The new optional callbacks are `worker_control/2`, `set_worker_mode/5` and
`worker_maintenance/5`. Advertise `worker_control: 1` only after implementing the
atomic gates in **all** admission paths. No execution/machine codec change is needed.
Run `SmolBox.Store.WorkerControlContract` against the adapter's real transaction
implementation, alongside the machine, capture, export and branch suites.

The PostgreSQL example adds migration
`20260929000000_worker_admission_controls`. It stores admission state separately
from leases and preserves mode/version history across lease takeover. Transactions
use the existing partition lock for both control changes and admission. Missing
schema fails capability checks; it is never interpreted as active admission.

Stop all controllers using that store authority, apply the migration, upgrade every
writer and restart them before relying on durable draining. Existing
`WorkerConfig.draining: true` remains a local configured restriction; convert any
previous in-memory drain intent into a durable drain explicitly. The old intent
cannot be recovered automatically after its controller exits.

Mixed old/new writers are unsupported: an old PostgreSQL adapter can bypass the
new gate. Do not roll back controllers during maintenance relying on this feature.
The down migration refuses to discard nonempty control history, including active
rows whose versions protect against stale requests. Preserve that history and
coordinate every writer before planning rollback; deleting drain rows is not a
routine reset procedure.

Adapters without the capability can still run ordinary work. Explicit drain,
resume and maintenance calls return `:unsupported_capability`; this is an intentional
change from the previous runtime-local convenience drain. Hosts that cannot upgrade
yet must coordinate their own static admission restrictions and maintenance policy.

## Validation

Shared memory/PostgreSQL contract tests cover concurrent drain/reservation ordering,
versioned resume, helper admission, duplicate histories and maintenance pagination.
Runtime tests cover two controllers, controller restart, retained commands and
cleanup during draining, static restrictions and unavailable storage. PostgreSQL
tests additionally check rollback and missing-schema behavior. These simulated
worker tests establish the store/controller contract, not worker-side fencing.

A live Linux run with smolvm 1.20.2 and PostgreSQL also exercised the following
sequence across two separate Elixir processes:

1. Create a retained machine, write a file and persist a drain revision.
2. Start a new controller process against the same database. Verify that it reads
   the drain and that a new request expires without a worker assignment.
3. Read the original file, stop and start the same machine, and read it again.
4. Explicitly delete that machine, verify absence and released reservations, then
   inspect the empty maintenance report and explicitly resume with its version.

The worker inventory was empty after this run and the dedicated test service was
stopped. This verifies retained-machine recovery and cleanup during draining; it
does not establish automatic shutdown safety or worker-side request fencing.

The PostgreSQL migration was separately exercised in both directions. Rollback
refused to discard an existing drain revision and left it intact. With only the
test history removed, rollback and reapplication succeeded. The ordinary library,
PostgreSQL adapter and published-dependency community example suites, package
consumer check and static quality checks cover compatibility independently of this
live scenario. No macOS VM campaign was run for this feature.

The [1.22.0 qualification](runtime-1.22.0-qualification.md) records the newer
platform checks. The historical validation above still describes its original run.
