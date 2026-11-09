# Upgrading SmolBox

Use this guide for an existing deployment. For a new application, begin with
[Embedded Port quickstart](embedded-quickstart.md). Release descriptions are in the
[changelog](https://github.com/hfiguera/smolbox/blob/main/CHANGELOG.md); the guides
below describe actions needed when crossing each release boundary.

For an existing embedded worker, follow the
[Embedded Port upgrade and drain procedure](embedded-port.md#upgrade-and-drain-procedure)
for helper approval and shared-store reader compatibility.

## Choose your upgrade path

When upgrading to 0.5.0, follow applicable steps in release order. You can
deploy the target library once, after accounting for the intervening requirements.

| If your application predates | Required action | Detailed instructions |
| --- | --- | --- |
| 0.2.0 | Coordinate controllers and store adapters; add managed machine and port ownership support | [Upgrade to 0.2.0](upgrading-to-0.2.0.md) |
| 0.2.1 | Pin workers and checkpoint approvals, or separately adopt smolvm 1.19.0 | [Upgrade to 0.2.1](upgrading-to-0.2.1.md) |
| 0.3.0 | Upgrade shared readers and adapters before writing registry, export, capture or branch records | [Upgrade to 0.3.0](upgrading-to-0.3.0.md) |
| 0.3.1 | Pin workers and checkpoint approvals, or separately adopt smolvm 1.20.2; update Mint | [Upgrade to 0.3.1](upgrading-to-0.3.1.md) |
| 0.4.0 | Apply the PostgreSQL example's worker-control and volume migrations; coordinate all shared writers | [Upgrade to 0.4.0](upgrading-to-0.4.0.md) |
| 0.4.1 | Pin workers and checkpoint approvals, or separately adopt smolvm 1.22.0; coordinate readers of runtime receipts | [Upgrade to 0.4.1](upgrading-to-0.4.1.md) |
| 0.4.2 | Upgrade every shared reader and custom error decoder before recording `:unsupported_network_policy` | [Upgrade to 0.4.2](upgrading-to-0.4.2.md) |
| 0.4.3 | Update and restart controllers; account for the independent maintenance task if monitoring task counts | [Upgrade to 0.4.3](upgrading-to-0.4.3.md) |
| 0.5.0 | Apply the PostgreSQL example's backend-bindings migration and coordinate store readers before enabling Embedded Port | [Upgrade to 0.5.0](#upgrade-to-0-5-0) |

SQL migrations belong to the supplied PostgreSQL example. Custom stores need
equivalent atomic behavior rather than those particular tables. Applications
coming from 0.1.2 or earlier must also account for the
[upgrades within 0.1.x](upgrading-within-0.1.x.md).

## Upgrade to 0.5.0

Keep existing HTTP worker versions and approvals pinned. Existing HTTP workers
can continue to serve the upgraded Runtime. Embedded Port targets require a
separate approved native package and enrolled domain.

Before enabling Embedded Port on a shared store, upgrade every controller,
reader and writer together. Native records select newer codecs according to
their retained history, and older readers can reject those records even after
cleanup. Apply migration `20261010000000_backend_bindings` before using the
supplied PostgreSQL adapter. Custom adapters must supply the corresponding
atomic backend and recovery capabilities.

For a retained Embedded Port domain, follow the
[upgrade and drain procedure](embedded-port.md#upgrade-and-drain-procedure).
Keep its installed paths, manifest and domain identity available during the
upgrade.

## Before changing the dependency

1. Record installed worker versions, controller versions and every application
   sharing the durable store. Include background readers and projection writers.
2. Keep worker IDs, store partitions, fingerprint and encryption keys, artifact
   approvals and checkpoint capture versions. Back up durable storage and account
   for worker disks and saved artifacts separately.
3. Follow the required guide's admission and coordination steps. A controller
   restart or expired lease cannot cancel a request already sent to a worker.
   Preserve unknown work; do not replay it to complete an upgrade.
4. Update the dependency and lockfile, deploy compatible adapters and readers,
   then verify existing records, recovery and cleanup before resuming submissions.

## Keep worker installation separate

Changing the Elixir dependency does not install smolvm or migrate its disks.
Set each worker's `runtime_version` to the version actually installed, and keep
checkpoint approvals pinned to their capture version. If changing the worker,
follow [Upgrading a worker](host-integration.md#upgrading-a-worker). See
[Supported platforms](supported-platforms.md) for selectable versions.

The published 0.2.1, 0.3.1 and 0.4.1 patches changed the default selected when a
runtime version was omitted. Version 0.4.2 kept the worker default but added an
error category that older stored-record readers reject. Read the applicable
instructions even when crossing only a patch release.

## Plan rollback before writing new records

Older readers can reject new record formats or values even without a SQL migration
or codec revision. Deleted machines and finished executions retain history.
Deleting resources does not restore compatibility, and reverting application code
alone does not undo worker or registry changes.

Keep compatible readers available, or plan a coordinated recovery using backups
and the actual external state. Do not erase history or strip fields to force an
older decoder to accept a record. Each release guide identifies its specific
rollback limits.
