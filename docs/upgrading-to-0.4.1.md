# Upgrade to 0.4.1

When crossing this release from 0.4.0, an omitted `runtime_version` changes
from **1.20.2** to **1.22.0**. Before updating the dependency, choose whether to
keep the installed worker or upgrade it separately. For all steps needed from
an older release, use [Upgrading SmolBox](upgrading.md).

## Keep an existing worker

Set the installed version explicitly on every controller using that worker:

```elixir
{:ok, worker} = SmolBox.Runtime.WorkerConfig.new(
  Keyword.put(existing_worker_options, :runtime_version, "1.20.2")
)
```

Keep checkpoint approvals pinned to their capture runtime, platform, architecture
and profile. `SmolBox.Checkpoint.new/1` also defaults to 1.22.0 in this release;
existing 1.20.2 checkpoints must continue to declare that version. Never relabel
old checkpoint bytes. The minimal and durable examples accept
`SMOLBOX_RUNTIME_VERSION=1.20.2`.

## Adopt smolvm 1.22.0

Follow [Upgrading a worker](host-integration.md#upgrading-a-worker). Install the
complete matching distribution, verify prerequisites, approvals and capacity,
and keep configuration consistent across shared controllers. A version mismatch
blocks new work; there is no automatic fallback.

Preserve worker disks, metadata, keys and original approvals before maintenance.
The [worker test report](runtime-1.22.0-qualification.md) uses fresh state; it does
not establish in-place upgrades of retained worker state or restore across
checkpoint versions. Do not replace a missing retained machine with an empty one.

Budget image seed preparation and caches separately from machine reservations.
See [image preparation controls](images-and-registry-artifacts.md) for the
worker's `SMOLVM_IMAGE_SEEDS` setting. SmolBox reservations do not limit every
file the worker creates.

## Storage and rollback

No SQL migration, store capability or codec revision is added from 0.4.0.
However, older readers can reject retained records containing
`runtime_version: "1.22.0"`. Upgrade every controller and reader sharing the
store before producing those records, including checkpoint and export receipts.
Keep readers compatible when rolling back; deletion leaves history and does not
remove the new runtime value.

Worker database and disk downgrades need a separate recovery plan using backups
and the original runtime pins. Updating the Elixir dependency does not install,
restart or downgrade a worker.

## Update and verify

After the coordination steps above, update the dependency and lockfile:

```elixir
{:smolbox, "~> 0.4.1"}
```

Run `mix deps.update smolbox` and compile the application.
Before resuming admission, verify existing records, a representative execution,
file persistence through stop/start and cleanup. Preserve unknown outcomes:
a disconnected terminal or lost response does not authorize replay or release
of a reservation. See [Recovery](recovery.md) for resolution procedures.
