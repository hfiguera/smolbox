# Local volumes and controlled mounts

A retained machine keeps its own disks until deletion. A managed local volume has
its own identity and lifetime: delete the machine, then attach the same data to a
replacement on the same worker. Use this for project data or a reusable cache.

This initial implementation supports **Linux workers running smolvm 1.20.2**, one
exclusive machine attachment per volume, and guest targets below `/mnt/volumes/`.
Read-only attachments are exclusive too. The default remains no mounts.

## Approve the worker storage boundary

The host must approve a `SmolBox.VolumePolicy` in its `WorkerConfig`:

```elixir
{:ok, volume_policy} = SmolBox.VolumePolicy.new(
  "project-data", "/srv/smolvm/.local/share/smolvm/volumes")

# Include volume_policy: volume_policy in WorkerConfig.new/1, along with
# your existing client, artifact/profile approvals and capacity.
```

Replace that example root with the **actual canonical local volume directory used
by the worker**. smolvm chooses it from its host configuration. SmolBox compares
the returned `node_path` with this root plus the generated volume ID. A mismatch
leaves the volume uncertain and its reservation held; it does not authorize a mount.

Approval means the operator has verified:

- The root and its parents cannot be substituted by symlinks or changed by guests.
- This worker and volume root belong to one durable store authority. Independent
  stores, manual volume creation with SmolBox IDs and external host writers are
  outside the ownership contract.
- File permissions work across replacement machines under the actual worker UID
  configuration. Upstream local volumes are directories initially created with
  mode `0777`. Root-run workers may assign different host UIDs to different VMs;
  a file writable by one VM is not automatically writable by its replacement.
- Host storage quotas, permissions and free space monitoring are configured.
  **`size_gb` is an advisory reservation, not an enforced filesystem quota.** A
  guest can consume more than its reservation unless the host enforces limits.

The native Linux campaign used an unprivileged worker with one host UID. It does
not qualify isolation or replacement writes under root-run workers with separate
VM UIDs. Do not broaden host permissions blindly to make a replacement work.

The managed API never accepts a caller's host source path. Scope authorization is
still the application's responsibility. A scoped volume ID is not an access token.

## Create, attach and reuse

With a configured runtime and a durable store advertising `local_volumes: 1`:

```elixir
{:ok, volume} = SmolBox.Volumes.create(MyApp.SmolBox,
  scope: "team-a", id: "project-data", worker_id: "linux-1", size_gb: 4)

{:ok, record} = SmolBox.Volumes.inspect(MyApp.SmolBox, volume)
# Continue only when record.state == :ready.

{:ok, mount} = SmolBox.VolumeMount.new("project-data", "/mnt/volumes/project")
{:ok, spec} = SmolBox.ManagedMachineSpec.new(
  scope: "team-a", id: "builder-one", artifact: approved_artifact,
  profile: approved_profile, volumes: [mount])
{:ok, machine} = SmolBox.Machines.create(MyApp.SmolBox, spec)
```

Use the normal managed start and command APIs. For example, a command can write
`/mnt/volumes/project/result.txt`. Command completion and cancellation retain both
the machine and its volume. A background process can continue accessing the volume;
a stopped observation does not release the attachment.

After **verified machine deletion**, create `builder-two` with the same volume
reference. The replacement is pinned to that volume's worker and sees the files.
Its own machine disks start from the approved image. A controller restart reads
the same volume identity, attachment and reservation from the store.

Mounts are immutable creation configuration, with up to eight distinct volume IDs
and nonoverlapping guest targets. The constructor sorts targets. Multiple volumes
on one machine must belong to the same worker. Set `readonly: true` in
`VolumeMount.new/3` to deny guest writes. Ordinary command working-directory and
file-transfer policies remain separate; approving a mount does not broaden them.

There is no hot attach/detach, concurrent sharing, migration, replication or automatic
volume expiry. Mounted machines cannot currently be checkpoint sources, checkpoint
restores, branches, exported machines or targets of disk expansion. Those paths
need separate semantics for externally retained data. Ordinary disposable execution
still has no managed volume option.

## Retention, accounting and deletion

`Volumes.list(runtime, scope, cursor: cursor, limit: 50)` returns durable records,
including deleted identities, with a next cursor. `inspect/2` exposes state,
version, worker, policy and `attached_to` (the scoped machine handle or `nil`).

- Volume states `:creating`, `:ready`, `:deleting` and `:unknown` reserve their full
  disk allowance. They reserve no CPU, memory or machine slots.
- Machine reservations cover the machine's own disks and other resources. Deleting
  a machine releases its attachment, **not** the volume's disk allowance.
- Worker draining atomically blocks new volumes and new attachments. Existing
  identity lookups and explicit cleanup remain available. Worker maintenance pages
  include retained volumes as blockers, even with no machines left.
- No execution retention policy removes a volume or its identity history.

Delete an unattached ready volume explicitly:

```elixir
{:ok, record} = SmolBox.Volumes.inspect(MyApp.SmolBox, volume)
{:ok, result} = SmolBox.Volumes.delete(MyApp.SmolBox, volume, record.version)
# Only result.state == :deleted confirms completion and releases accounting.
```

Deletion removes the worker directory and its contents. An attached volume cannot
be deleted, including while its machine is stopped or uncertain. This is stronger
than upstream's running-machine-only check. A worker **204 acknowledgment** completes
deletion; an unavailable worker, 404, malformed reply or lost response does not.
The upstream API has no volume inspect/list endpoint, so it cannot provide a
separate read-after-delete receipt. Under the approved exclusive-root policy,
SmolBox relies on that explicit deletion acknowledgment. The live campaign also
verified physical directory absence on the host.

Creation persists a generated worker ID and intent before dispatch. A duplicate
scoped ID with the same immutable request returns the existing handle without
another worker call. Changing size, worker or policy under that ID conflicts.
Deleted IDs remain tombstones and cannot be reused to create empty data. Use a new
ID for a new volume. Deletion retries with the original request version return the
recorded outcome; competing versions cannot dispatch twice.

## Uncertain outcomes and recovery

A returned handle means durable acceptance, not necessarily successful provisioning.
Inspect it. Caller loss, controller loss or a store failure can leave `:creating`,
`:deleting` or `:unknown` state. No background reconciler replays these requests.
Upstream has no ownership token or volume lookup, so SmolBox does not adopt a
host directory or mark an uncertain create ready from its name or path.

1. Preserve the volume record, generated worker ID, policy and attachment evidence.
2. Keep its disk reservation. Block new attachments while its state is uncertain.
3. Fence all pending worker requests at the host boundary before cleanup. Store
   versions, controller restart, an expired lease and observed VM stop do not fence
   a request already sent to the worker.
4. Once unattached and quiesced, explicitly resolve by deleting the owned storage:

   ```elixir
   {:ok, record} = SmolBox.Volumes.inspect(MyApp.SmolBox, volume)
   {:ok, result} = SmolBox.Volumes.resolve_delete(
     MyApp.SmolBox, volume, record.version, quiesced: true)
   ```

This assertion is an operator responsibility, not fencing implemented by the
library. It is a destructive resolution, not a retry of provisioning. If files
may matter, preserve them through a host-approved backup procedure first. A new
uncertain deletion still retains accounting. A changed/revoked worker policy blocks
mutation; restore the original approved boundary only after checking host identity.
Never silently recreate a volume that disappeared from the worker disk.

## Low-level client

`Client.provision_volume(client, owned_id, size_gb)` sends one local provisioning
request and returns `{:ok, node_path}`. `Client.delete_volume(client, owned_id)`
requires an empty 204 response. These functions neither authorize the path nor
manage retention, reservations, attachment ownership or recovery.

`Mount.new(source, target, readonly: true)` builds a low-level mount accepted by
`MachineSpec.new(name, artifact_path, mounts: [mount])`. Low-level callers own host
path approval. Staged mounts, traversal, overlapping targets and system directory
targets are rejected. Observations decode source, target and read-only state;
these fields participate in managed ownership checks before mutations.

Custom transports must honor optional `expected_status: 204` for empty volume
deletion responses, rather than treating every successful HTTP status as equivalent.

## Store contract and coordinated upgrades

The optional named store callbacks are `volume_accept/3`, `volume_fetch/2`,
`volume_list/4` and `volume_change/5`. Advertise `local_volumes: 1` only when these
callbacks **and** machine attachment/release, usage, capacity admission and draining
are atomic under the same store authority. `VolumeOps` contains shared transitions.
The memory adapter implements the contract but remains ephemeral.

The PostgreSQL example adds migration `20260930000000_local_volumes`. Encrypted
volume records live in `smolbox_volumes`; they have authenticated resource
projections and participate in the existing partition transaction. Volume bytes,
mounted managed machines and their command observations use codec **v15**. Ordinary
records keep earlier encodings and fingerprints; old records gain empty mount fields
on read. Maintenance cursors add volume kind `2`.

Stop all writers, apply migrations, and upgrade all controllers, store adapters,
readers and projection writers before enabling volumes. Old writers do not account
for retained volumes and old readers cannot decode v15. Rollback to incompatible
code is unsupported while v15 records exist, including deleted tombstones. The SQL
down migration refuses to discard volume history. Do not erase deduplication records
to force a rollback. Existing users who do not opt into volumes retain their prior
API behavior; this example adapter still requires its new migration when upgraded.

## Runnable example and validation

The [durable host example](../examples/durable_host/README.md#local-volumes) includes
`SmolBox.DurableHost.VolumeDemo`. Run `prepare` and `resume` in separate BEAM processes
with the same PostgreSQL partition, keys and volume policy. The flow writes a file,
deletes the original, reconnects after restart, reads/modifies it in a replacement,
checks a read-only attachment and deletes all machines and the volume.

[Native Linux evidence](evidence/local-volumes-linux-1.20.2.json) records the successful
smolvm 1.20.2 run with PostgreSQL, physical directory absence and zero final
reservations. The dedicated worker was stopped afterward. No macOS or nested Linux
volume qualification is claimed.

Simulated HTTP and shared memory/PostgreSQL contract tests separately exercise
competing attachments, identity conflicts, drain gates, atomic rollback, store
failures before/after persistence, lost responses, interrupted callers, changed
mount observations, record limits and malformed codec/wire inputs. These are
failure-injection coverage, not evidence of host quotas or multi-tenant isolation.
