# Upgrading to SmolBox 0.4.1

SmolBox 0.4.1 qualifies smolvm **1.22.0** on Linux x86_64 and macOS Apple Silicon
and selects it when the runtime version is omitted. Version 0.4.0 selected
1.20.2. Updating the Elixir dependency does not install or restart a worker.

## Keep an existing worker

Before upgrading, make the installed version explicit on every controller:

```elixir
{:ok, worker} = SmolBox.Runtime.WorkerConfig.new(
  Keyword.put(existing_worker_options, :runtime_version, "1.20.2")
)
```

Keep checkpoint approvals pinned to their exact capture runtime, platform,
architecture and profile. `SmolBox.Checkpoint.new/1` now defaults to 1.22.0;
existing 1.20.2 checkpoints must still declare `runtime_version: "1.20.2"`.
Never relabel old checkpoint bytes to satisfy a newer worker configuration.

Update the dependency and lockfile through your normal deployment process:

```elixir
{:smolbox, "~> 0.4.1"}
```

The minimal and durable host examples accept `SMOLBOX_RUNTIME_VERSION=1.20.2`.
The community workspace retains its published 0.3.0 dependency and explicit
runtime configuration so the existing tutorials remain reproducible. This patch
does not upgrade that app's worker or rewrite historical benchmark results.

## Adopt smolvm 1.22.0

Follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker).
Install the complete matching distribution, including the agent and VMM
libraries. Verify prerequisites, artifact approvals and host capacity before
admitting work, and keep configuration consistent across controllers sharing a
store. A version mismatch blocks new work; there is no automatic fallback.

Account for upstream image seed preparation and caching in addition to machine
reservations. The [qualification report](runtime-1.22.0-qualification.md) records
the observed host budget and platform coverage. SmolBox reservations are not a
quota for every file the worker creates.

The campaign used fresh worker state. It does not establish in-place upgrades of
retained worker databases or cross-version checkpoint restore. Preserve disks,
metadata, original keys, approvals and ownership evidence before maintenance.
Never replace a missing retained machine with an empty one.

The tested terminal process tree was cleaned up on disconnect with 1.22.0, but
this is not a general cancellation guarantee. Without an observed exit, an
uncertain command remains unknown and blocks reuse; do not replay it or release
its reservation based only on a disconnected browser.

## Storage and rollback

Upgrading from 0.4.0 adds **no SQL migration, store capability or codec revision**.
Public operation shapes and adapter callbacks remain unchanged. However, older
readers can reject records containing `runtime_version: "1.22.0"`.

Upgrade shared controllers and readers before producing those records. Keeping
the same codec revision does not make every new value readable by an older
release. Deleting a machine retains its history and does not undo this
requirement. Reverting application code alone is not a complete rollback.
Worker database rollback and downgrading retained disks are not qualified;
plan recovery separately using verified backups and original runtime pins.

Applications coming from 0.3.x must first follow
[Upgrading to 0.4.0](upgrading-to-0.4.0.md), including the worker-control and volume
migrations and coordinated adapter changes. Applications coming from 0.2.x must
also follow [Upgrading to 0.3.0](upgrading-to-0.3.0.md); applications coming from
0.1.x must first follow [Upgrading to 0.2.0](upgrading-to-0.2.0.md).

## Qualification and version policy

Qualification remains `:development`. The isolated macOS creation HTTP 500
recorded during qualification did not recur in the follow-up campaigns. Its
cause remains unknown; it is documented as a non-blocking observation, not a
fixed defect or a confirmed runtime regression.

During 0.x development, patch releases may change the qualified default worker.
Set explicit runtime versions when you need stable worker expectations. Earlier
supported versions remain selectable under their existing platform and feature
limits; intermediate upstream releases are not automatically admitted.
