# Upgrades within 0.1.x

These instructions apply to the original 0.1.x releases. For a target of 0.4.3,
account for these early transitions and then follow [Upgrading SmolBox](upgrading.md).
Install the target dependency after coordinating all applicable requirements.
The worker versions and defaults below describe each historical release.

## Upgrading to 0.1.3

SmolBox 0.1.3 introduces record schema v2 to persist network policies. Despite the
patch version number, this is a deployment compatibility change for applications
using `SmolBox.Store.Codec`, including the PostgreSQL example. A **controller** is
an Elixir application instance running SmolBox, not a smolvm worker.

| Reader | Legacy v1 records | New v2 records |
|---|---|---|
| SmolBox 0.1.2 | Supported | Rejected |
| SmolBox 0.1.3–0.1.5 | Supported as offline | Supported |

**In 0.1.3 and 0.1.4, every new codec write uses v2, even when networking stays offline.**
Version 0.1.5 retains this format for images and adds v3 for checkpoints. Reading a
valid v1 record adds offline defaults in memory without changing its execution
fingerprint or immediately rewriting the stored bytes. Its next save uses v2.
Upgrading the SQL schema alone cannot make an old reader understand those bytes.
Custom adapters with their own serialization need an equivalent migration plan.

For controllers sharing a durable store:

1. Pause new submissions and drain active work, including collection, cleanup
   and reservation release. Resolve retained or unknown work through the existing
   recovery procedure; do not delete its records to make the upgrade proceed.
2. Stop every old controller and any other process reading or writing these
   records. Do not leave 0.1.2 instances running during a rolling deployment.
3. Back up durable data and preserve the existing fingerprint key, encryption
   configuration, execution identities and worker ownership information.
4. Deploy 0.1.3 to all readers and writers. Its default worker version is 1.16.0;
   follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker)
   or explicitly keep `runtime_version: "1.14.6"` or `"1.14.1"` for older workers.
   The library does not install or upgrade smolvm. Network policies require 1.16.0.
5. Verify existing records remain readable and duplicates retain their identity.
   Resume submissions after confirming the configured workers pass version checks
   and recovery is operating with the same durable state and keys.

**Rollback:** before any v2 record is written, the record format does not prevent
returning to 0.1.2, provided its worker configuration is still compatible. After
v2 writes, there is no built-in downgrade to v1. Keep a compatible reader or plan
an explicit, reviewed migration. Simply restoring an earlier database backup can
lose evidence of commands already accepted by workers and lead to duplicate work.
A decoding failure must remain an error, never be treated as a missing execution.

The in-memory store is ephemeral and is not a persistence migration strategy.
Restarting it loses execution records and may leave machines behind. Applications
using only `SmolBox.Client` do not use this managed record format, but must still
check their worker version and any persistence they own.

## Upgrading to 0.1.4

SmolBox 0.1.4 changes the default worker from smolvm 1.16.0 to **1.16.1**.
Updating the Elixir dependency does not install or upgrade that worker. Before
updating an application, choose one of these paths:

- Retain an existing worker by setting `runtime_version: "1.16.0"` explicitly
  in every controller that owns it. Explicit 1.14.6 and 1.14.1 offline workers
  remain supported too.
- Upgrade the worker using the [drain and verification procedure](host-integration.md#upgrading-a-worker).
  Resolve existing work and preserve its state before replacing the complete
  runtime distribution. Configure every owner to expect 1.16.1 and verify an
  owned execution through cleanup before resuming submissions.

Version checks require an exact match; there is no automatic fallback.
Controlled networking works with 1.16.0 and 1.16.1 and remains offline by default.

There is **no additional record schema migration from 0.1.3**: both versions read
v1 records and write v2. Applications coming from 0.1.2 or earlier must also
complete [the 0.1.3 record upgrade](#upgrading-to-0-1-3).

Managed cleanup now separates disposal from preservation, as described in
[Preservation and disposal](recovery.md#preservation-and-disposal). Completed work can
remove its owned machine without a preliminary graceful stop. Unknown work still
retains its disks and reservation during its retention period. A failed graceful
stop never automatically authorizes deletion, and retry exhaustion may still
require operator resolution. Upgrading does not reset exhausted cleanup budgets
or replay commands with uncertain outcomes.

## Upgrading to 0.1.5

Version 0.1.5 adds approved idle, offline checkpoint execution. It keeps smolvm
1.16.1 as the default; no worker upgrade is needed from 0.1.4. Checkpoints require
1.16.1 on Linux x86_64 or macOS Apple Silicon. Image executions retain explicit
1.16.0, 1.14.6 and 1.14.1 support and their existing network/version restrictions.

Image records continue to use schema v2 with unchanged fingerprints. Only
checkpoint executions write schema v3. The 0.1.5 codec reads v1, v2 and v3; older
controllers cannot read v3. A controller is an Elixir application running SmolBox,
not a smolvm worker. This changes the stored payload, not the PostgreSQL example's
SQL tables, encryption envelope or store adapter contract.

Before enabling checkpoint submissions against a shared store:

1. Keep checkpoint submissions disabled. Inventory every controller and other
   process that reads or reconciles the store, including standby instances.
2. Drain controllers through your normal upgrade procedure, preserving pending
   cleanup, reservations and unknown outcomes. Back up the store and retain its
   fingerprint and encryption keys; do not erase records to permit an upgrade.
3. Upgrade every reader/controller to 0.1.5. Verify existing records can be read
   and observation/cleanup resumes without replaying commands.
4. Register an approved checkpoint on a compatible 1.16.1 worker. Validate one
   execution through result collection, verified deletion and capacity release
   before enabling checkpoint submissions for the application.

Image-only use introduces no v3 records and does not require the checkpoint
coordination step. Applications coming from 0.1.2 or earlier still need
[the v2 record upgrade](#upgrading-to-0-1-3); applications coming from 0.1.3 must
also review [the worker change in 0.1.4](#upgrading-to-0-1-4).

**Rollback:** once any v3 records exist, disabling new checkpoint submissions is
not enough to downgrade controllers. Completed checkpoint records are still v3.
Retain compatible readers, or explicitly separate/migrate those records while
preserving identity, deduplication and cleanup evidence. There is no automatic
conversion to v2 and no supported blind rollback to 0.1.4.

See [Checkpoint approval](checkpoints.md#prepare-and-approve-the-source) for
captured-state restrictions and [checkpoint validation](checkpoints.md#performance-and-validation)
for the measured behavior and platform boundaries.
