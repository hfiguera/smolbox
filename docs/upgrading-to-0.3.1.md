# Upgrading to SmolBox 0.3.1

SmolBox 0.3.1 qualifies smolvm **1.20.2** on Linux x86_64 and macOS Apple Silicon
and selects it when the runtime version is omitted. Version 0.3.0 selected
1.19.0. Updating the Elixir dependency does not install or restart a worker.

## Keep an existing worker

Before upgrading, make its installed version explicit on every controller:

```elixir
{:ok, worker} = SmolBox.Runtime.WorkerConfig.new(
  Keyword.put(existing_worker_options, :runtime_version, "1.19.0")
)
```

Keep checkpoint approvals pinned to their exact capture runtime, platform,
architecture and profile too. `SmolBox.Checkpoint.new/1` now defaults to 1.20.2;
existing 1.19.0 checkpoints must still declare `runtime_version: "1.19.0"`.
Never relabel old checkpoint bytes to satisfy a newer worker configuration.
Both `.smolcheckpoint` and `.checkpoint` are accepted; changing a filename does
not convert its contents. Managed capture filenames remain unchanged.

Update the dependency and lockfile through your normal deployment process:

```elixir
{:smolbox, "~> 0.3.1"}
```

The minimal and durable host examples accept `SMOLBOX_RUNTIME_VERSION=1.19.0`.
The community workspace keeps its published 0.3.0 package lock and the saved
state walkthrough's explicit 1.19.0 worker configuration. This release does not
silently upgrade that app's worker or rewrite historical benchmark results.

## Adopt smolvm 1.20.2

Follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker).
Install the complete matching distribution, including the agent and VMM
libraries. Verify prerequisites, artifact approvals and capacity before enabling
work, and keep configuration consistent across controllers sharing a store.
A version mismatch blocks new work; SmolBox does not fall back automatically.

The [qualification report](runtime-1.20.2-qualification.md) records real Linux
and macOS checks and their limits. These fresh-worker tests do not establish
in-place upgrades of retained worker state or cross-version checkpoint restore.
Preserve disks, metadata, original keys, approvals and ownership evidence before
maintenance. Never replace a missing retained machine with an empty one.

Terminal disconnect behavior can differ with the new worker: the probe's
detached descendant stopped on 1.20.2, but that is not a general cancellation
guarantee. Without an observed exit notification the outcome remains unknown;
do not replay work or clear its reservation based only on a disconnected browser.

## Storage and rollback

Upgrading from 0.3.0 adds **no SQL migration, store capability or codec revision**.
Public operation shapes and adapter callbacks remain unchanged. However,
checkpoint and export receipts can now contain `runtime_version: "1.20.2"`,
which older readers can reject. Exports record the actual worker version.

Upgrade all shared controllers and readers before producing those records.
Keeping the same codec revision does not make every new value readable by an
older release. Deleting a machine retains its history and does not undo this
requirement. Reverting only the application code is not a complete rollback.
Worker database rollback and downgrading retained disks are not qualified;
plan recovery separately using verified backups and original runtime pins.

Applications coming from 0.2.x must also follow
[Upgrading to 0.3.0](upgrading-to-0.3.0.md), including the store capabilities and
record formats introduced there. Applications coming from 0.1.x must first
follow the [0.2.0 migration](upgrading-to-0.2.0.md).

## Dependencies and version policy

Mint now requires `~> 1.11`; update the resolved dependency and review any host
overrides that constrain it to an older version. Qualification remains
`:development`, with no new production isolation certification.

During 0.x development, patch releases may change the qualified default worker.
Set explicit runtime versions when you need stable worker expectations, review
the upgrade notes and change worker installations deliberately. Previously
supported versions remain selectable under their existing platform and feature
limits; intermediate upstream releases are not automatically admitted.
