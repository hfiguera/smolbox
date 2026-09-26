# Upgrading to SmolBox 0.2.1

SmolBox 0.2.1 qualifies smolvm **1.19.0** on Linux x86_64 and macOS Apple Silicon
and selects it when `runtime_version` is omitted. Version 0.2.0 selected 1.17.0.
Updating the Elixir dependency does not install or upgrade smolvm on a worker.

**If your worker still runs 1.17.0, explicitly configure
`runtime_version: "1.17.0"` before upgrading SmolBox, or upgrade the worker
separately.** A version mismatch prevents new managed work from being admitted;
there is no automatic fallback to a different runtime.

## Keep an existing worker

Make the installed version explicit on every controller that uses that worker:

```elixir
{:ok, worker} = SmolBox.Runtime.WorkerConfig.new(
  Keyword.put(existing_worker_options, :runtime_version, "1.17.0")
)
```

Keep existing checkpoint approvals pinned to the version that captured them too.
`SmolBox.Checkpoint.new/1` now defaults to 1.19.0; an existing 1.17.0 checkpoint
must continue to declare `runtime_version: "1.17.0"`. Do not relabel checkpoint
bytes to satisfy a newer worker configuration.

Then update the dependency and lockfile through your normal deployment process:

```elixir
{:smolbox, "~> 0.2.1"}
```

The minimal and durable host examples accept `SMOLBOX_RUNTIME_VERSION=1.17.0`
to retain that worker. The community workspace example already explicitly pins
1.17.0 and keeps its published 0.2.0 dependency lock; it is not silently moved to
the new worker during this preparation.

## Adopt smolvm 1.19.0

Follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker).
Install the complete matching worker distribution, including libkrun and the
guest agent, and verify prerequisites, prepared artifacts and capacity floors.
Coordinate the worker configuration across controllers sharing ownership.

The [qualification report](runtime-1.19.0-qualification.md) covers fresh workers,
execution, persistence, recovery, checkpoints, networking and failure scenarios.
It does not establish an in-place upgrade of existing retained worker disks,
rollback of a modified upstream database, or cross-version checkpoint portability.
Preserve worker state, durable ownership records, original keys and artifact
approvals. Do not replace a missing retained machine with an empty one.

## Store compatibility and rollback

When upgrading from 0.2.0, this release introduces **no SmolBox store schema,
codec revision, feature capability or SQL migration**. Existing public operation
shapes and the `machine/3` adapter callback remain compatible. The explicit
managed-machine store types document the existing operation contract; adapters
do not need to implement renamed callbacks.

If you are upgrading from 0.1.x, first follow the coordinated
[0.2.0 controller and store upgrade](upgrading-to-0.2.0.md). The absence of new
migrations in 0.2.1 does not remove those earlier requirements.

SmolBox 0.2.0 does not admit 1.19.0 managed workers. Once a controller uses a
1.19.0 worker, reverting only the library to 0.2.0 is not a complete rollback.
Reverting SmolBox records does not downgrade worker disks or the upstream
worker database. Plan worker rollback separately using verified backups and the
original version configuration; this release does not qualify that procedure.

## Version policy during 0.x development

SmolBox 0.x patch releases may update the **qualified default worker version**
as smolvm evolves. The release notes and upgrade guide identify each change and
the explicitly supported versions. Applications that need a stable worker
expectation should set `runtime_version` on workers and checkpoint approvals,
review the release notes, and upgrade workers deliberately.

A patch release therefore does not promise that an omitted worker version will
select the same runtime forever. In 0.2.1, explicit 1.17.0 and previously supported
worker versions remain available under their existing feature/platform limits.
Arbitrary upstream versions are not accepted solely because they are newer.
