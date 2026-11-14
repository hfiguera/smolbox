# Upgrading SmolBox

Use this guide for an existing deployment. For a new application, begin with
[Embedded Port quickstart](embedded-quickstart.md). Release descriptions are in the
[changelog](https://github.com/hfiguera/smolbox/blob/main/CHANGELOG.md); the guides
below describe actions needed when crossing each release boundary.

For an existing embedded worker, follow the
[Embedded Port upgrade and drain procedure](embedded-port.md#upgrade-and-drain-procedure)
for helper approval and shared-store reader compatibility.

## Choose your upgrade path

When upgrading to 0.6.0, follow applicable steps in release order. You can
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
| 0.5.0 | Apply the PostgreSQL example's backend-bindings migration and coordinate store readers before enabling Embedded Port | [Upgrade to 0.5.0](#upgrade-to-050) |
| 0.5.1 | Pin existing workers and checkpoint captures, or adopt SmolVM 1.34.0 in a separately prepared deployment | [Upgrade to 0.5.1](#upgrade-to-051) |
| 0.6.0 | Upgrade shared readers and branch transactions before enabling release environments, static egress or native HTTPS credentials; approve the matching native bundle | [Upgrade to 0.6.0](#upgrade-to-060) |

SQL migrations belong to the supplied PostgreSQL example. Custom stores need
equivalent atomic behavior rather than those particular tables. Applications
coming from 0.1.2 or earlier must also account for the
[upgrades within 0.1.x](upgrading-within-0.1.x.md).

## Enable the unreleased Kubernetes preview

Upgrade every shared controller, reader and writer before enabling Kubernetes
records. They selectively use codec v54; existing HTTP/Embedded records retain
their previous envelopes and semantic fingerprints. Historical Kubernetes proof
versions 1/2 remain readable but cannot release capacity through the current
contract. Do not rewrite them as version 3.

Apply the supplied PostgreSQL example's
`20261113000000_kubernetes_bindings` migration before enrolling a target. Custom
stores must implement the atomic `kubernetes_backend: 1`, `backend_bindings: 1`
and `backend_recovery: 1` contracts, complete authenticated assignment/tombstone
scans and proof-bound release. A capability marker alone does not qualify a store.
Preserve the partition, encryption/fingerprint keys, controller guard directory,
ArtifactStore root and original node enrollment across controller restarts.

Follow [the preview guide](kubernetes-backend.md) for the approved runtime,
restricted RBAC, node history/lifecycle evidence and manual public smoke. Do not
reuse HTTP/Embedded deployment qualification as Kubernetes node authority.

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

## Upgrade to 0.5.1

SmolBox 0.5.1 selects SmolVM 1.34.0 when a worker or checkpoint approval omits
`runtime_version`. Set `runtime_version: "1.22.0"` on each existing 1.22.0
worker and its checkpoint approvals before updating the Elixir dependency.
Keep approvals pinned to the version and platform that captured each checkpoint.

The Embedded Port installer selects the 1.34.0 bundle by the SmolBox version.
Keep the original native package and domain available while draining and
reconciling its work. The 1.34.0 qualification used a fresh domain with its own
package and account. [Embedded Port upgrade and drain procedure](embedded-port.md#upgrade-and-drain-procedure)

## Upgrade to 0.6.0

SmolVM 1.34.0 remains the default. Preserve existing explicit worker versions,
checkpoint capture versions, backend bindings and domain generations. Updating
the Elixir dependency alone does not update an installed native helper.

Before enabling the new branch features, upgrade every controller, background
reader, store writer and resource projector sharing the affected records. Custom
stores must implement the corresponding atomic branch transitions before
advertising support; a capability flag alone is insufficient.

| Feature | Store capability and record format | Worker requirement |
| --- | --- | --- |
| Non-secret environment at held-child release | `branch_release_env: 1`, codec v51; four-argument release transaction with version-and-environment deduplication | SmolVM 1.34.0 HTTP worker or Embedded Port `branch_release_env: 1` |
| Static branch egress | `branch_static_egress: 1`, codec v52; preserve source and child static-egress intent | Linux x86_64 HTTP worker on 1.34.0 or Embedded Port `branch_static_egress: 1` |
| Embedded Port per-child HTTPS Bearer credentials | `native_branch_https_credentials: 1`, codec v53; pre-dispatch denial through `NativeBranchReleaseOps` | Linux x86_64 package advertising `branch_https_credentials: 1`; configure an explicit child resolver |

The supplied Memory store supports these capabilities. It remains ephemeral.
Durable/custom adapters must be upgraded independently. These changes add no SQL
migration to the supplied PostgreSQL example. See `SmolBox.Store` for the atomic
behavior required from an adapter.

Install and explicitly approve the matching 0.6.0 Embedded Port bundle using the
[upgrade and drain procedure](embedded-port.md#upgrade-and-drain-procedure).
Retain the prior helper, installed paths and protected template/cache references
until its owned work has been reconciled. Existing manifests remain subject to
their original feature approvals; they do not acquire new features from the
Elixir upgrade.

Release environments are persisted, so pass only non-secret values. Static
egress is opt-in and requires held children; portable checkpoints remain offline.
HTTPS credential branches use a checkpointable bare source with one approved
hostname, no CIDRs, and explicit per-child grants. Keep real credentials out of
the source snapshot. An Embedded Port child needs a valid binding on release and
each restart. A running child retains its installed key until stopped.
[Managed branch configuration and limits](managed-branches.md)

Retained records can use v51, v52 or v53 after these features are enabled.
Older readers can reject the histories even after VM deletion. Plan rollback
before accepting new work; preserve compatible readers or recover using a
coordinated backup and the actual worker state. Do not strip retained fields or
relabel envelopes to force an older reader to accept them.

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
