# Upgrade to 0.4.0

When crossing from 0.3.1, coordinate shared controllers and adapters and apply the
PostgreSQL example's two migrations before reopening admission. Draining now
requires a capable store rather than changing only the current controller's state.
The default worker stays **smolvm 1.20.2**. Use
[Upgrading SmolBox](upgrading.md) for steps from other releases.

## What changes in storage

| Feature | Store requirement | PostgreSQL example | Record format |
| --- | --- | --- | --- |
| Measurements and capacity reports | Existing accounting reads | No new schema | No new format |
| Durable draining | `worker_control: 1`; atomic gates on every admission path | `20260929000000_worker_admission_controls` | Separate mode/version history; no machine codec change |
| Disk expansion | `managed_disk_expansion: 1`; atomic capacity and drain checks | Existing encrypted records and resource projections | Selective codec v14 |
| Local volumes and mounts | `local_volumes: 1`; atomic volume admission, exclusive attachment, accounting and release | `20260930000000_local_volumes` | Selective codec v15 |

The updated PostgreSQL example requires **both migrations**, including for hosts
that do not enable volumes. Disk expansion needs no additional SQL table.
Ordinary records retain their earlier encodings and fingerprints. Expanded-machine
history and commands use v14; volume records, mounted machines and their command
observations use v15. Old readers cannot decode those formats. Deleted records
retain identity and history, so cleanup does not restore downgrade compatibility.

The memory adapter implements the new contracts but remains ephemeral. Restarting
its process loses its records; use a durable adapter for recovery across restarts.

## Coordinated deployment from 0.3.1

1. Pause new application submissions, including commands on retained machines.
   Inventory retained machines, active or unknown work, saved artifacts and any
   existing drain intent. Resolve or preserve that evidence through the documented
   recovery procedures; never replay an unknown command to finish an upgrade.
2. Stop every controller and other writer sharing the store authority. Coordinate
   direct worker clients too. Stopping a controller or observing a stopped machine
   does not fence worker requests already sent. Establish host quiescence before
   operations that depend on there being no outstanding mutations.
3. Back up the database, keys and configuration and preserve worker disks and
   artifacts. Keep encryption/fingerprint keys, store partitions, scoped identities,
   worker IDs and original source approvals. A database backup alone is not a
   backup of machine or volume contents.
4. Deploy compatible store code and apply all pending migrations before restarting
   controllers. From the updated PostgreSQL example, using the same configured
   database as the host:

   ```sh
   cd examples/durable_host
   mix deps.get
   mix ecto.migrate
   ```

   Existing 0.3.1 installations receive the two migrations listed above. Adapt this
   step to your deployment tooling; these are example-adapter migrations, not a
   database embedded in the library.
5. Upgrade all controllers, readers, store adapters and resource projection writers
   together. Do not run old and new writers against the same authority: older
   writers can bypass durable drain gates and omit retained-volume reservations.
6. Restart with consistent worker policy and verify existing records and resource
   totals. Convert any previous controller-local drain intent into a durable drain
   explicitly before reopening submissions. Its old in-memory state cannot be
   recovered automatically. Static `WorkerConfig.draining: true` remains a local
   restriction and must be changed deliberately before admission can resume.
7. Enable new operations only after their capability checks, worker approvals and
   host storage checks pass. Keep submissions paused during maintenance and use
   explicit versioned resume afterward. A maintenance report never certifies that
   shutting down a worker is safe.

## Custom adapters and transports

Existing adapters can continue ordinary work without advertising the optional new
capabilities. Explicit drain, resume and maintenance calls return
`:unsupported_capability` without `worker_control: 1`. Hosts relying on the former
local `drain_worker/2` behavior must implement the durable contract or coordinate
static admission restrictions themselves. On capable stores, `drain_worker/2`
still returns `:ok`; versioned operations provide stale-request protection.

Implement and validate the contracts before advertising them:

- Worker control: `worker_control/2`, `set_worker_mode/5`, `worker_maintenance/5`
  and atomic gates across all resource admission paths.
- Expansion: `:expansion_accept` and `:expansion_advance` under `Store.machine/3`,
  preserving immutable creation evidence and reserving the full growth target.
- Volumes: `volume_accept/3`, `volume_fetch/2`, `volume_list/4`, `volume_change/5`
  plus atomic attachment/release, usage, draining and maintenance reporting.

Run the shared `WorkerControlContract`, `ExpansionContract` and `VolumeContract`
against your adapter's actual transaction implementation, along with the existing
store contracts. Updating callback signatures alone is insufficient. Readers and
projection writers must understand the new records before they are persisted.
Maintenance cursors now include volume kind `2`.

Custom transports handling volume deletion must honor `expected_status: 204`;
another successful HTTP status is not equivalent deletion evidence.

## Worker and feature boundaries

Keep existing workers explicitly pinned to their installed version and checkpoints
to their capture runtime. The supported runtime list does not change from 0.3.1.
Hosts coming from 0.3.0 must also follow [Upgrading to 0.3.1](upgrading-to-0.3.1.md)
before relying on the 1.20.2 default or writing receipts with that runtime.

Before enabling new operations, follow the corresponding guide:

- [Measurements](worker-measurements.md): observations do not change reservations.
- [Draining](worker-draining.md): pause admissions and use explicit versioned resume.
- [Disk expansion](disk-expansion.md): approve growth of an idle stopped/created
  machine and verify usable space after a later boot.
- [Local volumes](local-volumes.md): approve a canonical Linux worker volume root,
  account for exclusive attachments and explicitly delete retained volumes.

The original growth and volume checks used Linux 1.20.2; they did not qualify
macOS growth or mounts. Mounted machines cannot be exported, checkpointed,
branched or expanded. Follow [Supported platforms](supported-platforms.md) and
the feature guides for current worker and platform restrictions.

## Rollback

Plan rollback before enabling the new operations. Older code cannot read v14/v15
history and may ignore volume reservations or durable drain gates. Deleting machines
and volumes leaves tombstones; it does not make an old reader safe to deploy.

The PostgreSQL down migrations refuse to discard nonempty worker-control or volume
history. Even an active worker-control row has a version that protects against stale
requests. Do not erase rows, rewrite record versions or remove tombstones to force
rollback. Before any schema rollback, check expanded/mounted machine and execution
history as well as the new tables; an empty volume table alone is insufficient.

If no new history has been written, a coordinated rollback may be possible after
verifying all records are readable by the previous code and no maintenance process
depends on durable draining. Stop all writers first. Otherwise retain compatible
readers/writers and plan recovery with backups and the actual worker state. Restoring
an old database while leaving newer machine disks or volumes behind is not a safe
rollback procedure. Upstream worker database and disk downgrades remain unqualified.

Applications coming from 0.2.x must also follow
[Upgrading to 0.3.0](upgrading-to-0.3.0.md). Applications coming from 0.1.x must
first follow [Upgrading to 0.2.0](upgrading-to-0.2.0.md).
