# Upgrade to 0.3.0

Before enabling registry sources, exports, managed checkpoint capture or branches,
upgrade all controllers, readers and adapters sharing their store. From 0.2.x,
no additional PostgreSQL SQL migration is needed, but the new records and
transactions still require coordinated deployment. The default stays
**smolvm 1.19.0** from 0.2.1. Use [Upgrading SmolBox](upgrading.md) for the complete
path from your installed release.

## Coordinate storage before using new features

The PostgreSQL example requires **no additional SQL migration from 0.2.x**.
It stores the new records in existing encrypted payloads and performs the new
operations inside its partition transactions. This does not make an older
adapter or reader compatible with new data.

Upgrade every controller, record reader and resource projection writer sharing
storage and workers before enabling the capabilities below. Mixed versions are
unsupported once new records are written. For a custom adapter, implement the
complete operation contract, atomic exclusion and accounting behavior before
advertising a capability. The memory adapter and PostgreSQL example implement
these contracts; memory storage alone cannot recover after a controller process
or application loses its store.

| Feature | Selective record version | Store capability | State that outlives the operation |
| --- | --- | --- | --- |
| Registry and OCI machine sources | v10 | `registry_sources: 1` | Preparation identity, ownership and uncertainty |
| Managed OCI image pulls | v10 | `managed_images: 1` | Pull identity and outcome, including uncertainty |
| Stopped-machine exports | v11 | `managed_exports: 1` | Publication claims and export history after machine deletion |
| Checkpoint opt-in and captures | v12 | `managed_checkpoints: 1` | Capture history and unreleased artifact disk reservations |
| Branch source and child history | v13 | `managed_branches: 1` | Lineage and backing allowances after child deletion |

Branch sources also require checkpoint opt-in and `managed_checkpoints: 1`.
Features retain any existing capabilities required by their machine specification.
These are selective encodings, not a rewrite of every record: records without
the new features preserve their earlier formats and identity fingerprints.
The codec supplies neutral defaults for older records.

The detailed adapter contracts and recovery procedures are in
[registry provisioning](images-and-registry-artifacts.md),
[exports](machine-exports.md), [managed checkpoints](managed-checkpoints.md) and
[branches](managed-branches.md). Use the repository's store contract tests when
qualifying a custom implementation; claiming a capability is not validation.

## Upgrade sequence

1. Back up the durable store and retain worker identities, artifact approvals,
   credential references and resource accounting evidence. Quiesce submissions
   and resolve or preserve in-flight operations before switching controllers.
2. Upgrade all shared readers, controllers and adapters to 0.3.0. Verify the
   adapter's new transactions and projections before advertising capabilities.
   Do not run an older resource projection writer against new machine records.
3. Keep workers explicitly pinned to their installed version. If upgrading from
   0.2.0 with a 1.17.0 worker, set `runtime_version: "1.17.0"` or upgrade that
   worker separately. New state-management features have their own 1.19.0 gates;
   admitting an older worker does not enable those features on it.
4. Configure only the required source, destination and checkpoint approvals,
   credential resolver references, host storage budgets and worker capacity.
   Try the corresponding durable example with a disposable machine and verify
   restart recovery and cleanup before admitting application workloads.

Applications upgrading from 0.1.x must first apply the coordinated
[0.2.0 upgrade](upgrading-to-0.2.0.md), including the example's machine and port
ownership migrations. This guide does not replace that procedure.

## Retention and accounting

Command completion does not delete a managed machine. New saved state has its
own lifetime too:

- Export publication does not delete the source or registry artifact. Uncertain
  work retains the operation slot and helper reservation. Verified publication
  still needs operator confirmation of quiescence before helper release.
- A captured checkpoint can retain its artifact disk reservation after source
  deletion. Explicit release requires the cleanup evidence described in the
  checkpoint guide; no automatic artifact deletion or garbage collection runs.
- A deleted branch child does not prove its source backing can be released.
  SmolBox conservatively retains the additional branch allowance until the
  required source/child absence and host backing cleanup are confirmed.
- Host image caches, registry storage and temporary files need separate host
  budgets. Machine reservations do not bound every upstream cache or download.

An observed stop or a store fence cannot fence a request already sent to a worker.
Unknown operations are not automatically replayed. Follow the feature's explicit
resolution procedure and preserve original identities instead of replacing a
missing machine or repeating a mutation with a new key.

## Rollback limits

Older releases cannot decode the new feature records. Deleting machines does not
remove publication claims, capture history, branch lineage or tombstones, and
therefore does not make downgrade safe. Do not strip fields, reservations or
history to force an older reader to accept a record.

Before any rollback, establish whether new formats were written and whether
worker or registry mutations are still possible. A store backup alone cannot
undo those external effects. Recovery needs a compatible reader or a coordinated
pre-feature backup with the worker/artifact state accounted for and all relevant
senders quiescent. Restoring only the database can lose ownership or deduplication
evidence while the corresponding machine or artifact still exists.

Worker rollback and in-place upgrades of retained disks are not qualified. Keep
checkpoint approvals pinned to the capture runtime and platform; these releases
do not establish cross-version or cross-platform snapshot portability.

## Verify the features you enable

Run the relevant [registry](images-and-registry-artifacts.md),
[export](machine-exports.md), [checkpoint](managed-checkpoints.md) or
[branch](managed-branches.md) workflow on a machine you own. Verify controller
recovery and the feature's separate retention and release steps. Keep checkpoints
pinned to their capture runtime and platform; these operations do not establish
restore across platforms or worker versions.
