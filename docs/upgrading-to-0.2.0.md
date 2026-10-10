# Upgrade to 0.2.0

When crossing from 0.1.x, coordinate all controllers and store adapters before
writing managed-machine records. This release defaults to **smolvm 1.17.0**;
pin an existing supported worker to its installed version or upgrade it separately.
Use [Upgrading SmolBox](upgrading.md) for steps through later releases.

## Required changes

- Apply the PostgreSQL example's managed-machine and port-ownership migrations,
  or implement the equivalent atomic contracts in a custom adapter.
- Upgrade every reader and writer before enabling records using codec v5–v9.
  The store capability table below identifies which contracts each feature needs.
- Refresh dependencies and verify packaged application recovery before resuming
  admission. Keep worker IDs, keys, approvals and retained resource accounting.

## Upgrade sequence

1. **Inventory and back up the deployment.** Record controller versions, shared
   stores, worker IDs and installed versions, artifact/checkpoint approvals,
   active/unknown executions, retained resources and private keys. Back up the
   durable store and artifact storage using the host's established procedures.
   Keep fingerprint/encryption keys stable; changing them is not a version upgrade.
2. **Stop admission and quiesce old controllers.** Let known work finish where
   practical and preserve unknown outcomes. Stop every old writer, background
   reconciler and reader sharing the store before enabling 0.2.0 writes. Store
   leases fence subsequent store writes, not HTTP requests already sent to a
   worker. A stopped observation alone does not establish request quiescence.
3. **Upgrade the store adapter.** The supplied memory adapter is ephemeral; it
   cannot supply process-restart durability. For the PostgreSQL example, back up
   first and run `mix ecto.migrate` from `examples/durable_host` against the intended
   database. This includes `20260922000000_managed_persistent_machines.exs` and
   `20260923000000_managed_port_ownership.exs`, plus any missing earlier migrations.
   Custom adapters must implement equivalent atomic contracts and advertise only
   the capabilities they actually preserve.
4. **Choose worker versions explicitly.** A previously omitted `runtime_version`
   now selects 1.17.0. To retain a 1.16.1 worker, set `runtime_version: "1.16.1"`
   before updating the library; earlier qualified image workers can likewise
   retain their explicit versions and restrictions. New image features require
   1.17.0. Follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker)
   for draining, installation, qualified binaries and artifact allocation floors.
5. **Upgrade all controllers and readers to 0.2.0.** Refresh dependencies, keep
   admission disabled, and verify existing records, assignments and reservations
   can be read and reconciled. Preserve worker identity and shared store authority;
   renaming a worker must not bypass ownership or capacity accounting.
6. **Enable approved features and resume admission.** Register exact immutable
   profiles and artifact approvals. Start with a representative retained-machine
   scenario: create, stage, execute, reconnect from a fresh controller, stop/start,
   execute again, delete, verify absence and released reservations. Inspect unknown
   work explicitly; never resolve it by replaying commands or replacing missing
   machines with empty ones.

Do not run schema downgrades or clear identity/history tables as a routine recovery
step. Database migration success alone does not prove application recovery.

## Record formats and capabilities

0.2.0 reads historical v1–v8 and new v9 records. It selects the appropriate write
format for the record's features; updating the package does not rewrite every
stored record to v9.

| Record features | Write envelope | Required feature capability |
| --- | --- | --- |
| Ordinary disposable image execution | v2 | Existing store contract |
| Ordinary disposable checkpoint execution | v3 | Existing checkpoint-compatible store contract |
| Ordinary retained machine and its commands, including no-port machines | v5 | `managed_machines: 1`; managed admission also requires `managed_ports: 1` |
| Background launch or extended execution budget | v6 | `extended_execution: 1` |
| Interactive execution | v7 | `interactive_terminal: 1` and `extended_execution: 1` |
| Startup workload machine | v8 | `managed_workloads: 1` |
| Explicit guest path policy or expanded file budget | v9 | `guest_files: 1` |

When features are combined, the newer applicable envelope preserves them together,
and **all applicable capabilities remain required**. For example, a terminal on
a machine with an explicit file policy uses v9 and still requires terminal and
extended-execution support. Exact historical v4 managed records gain empty port
fields on read. New v5–v9 records cannot be read by 0.1.5.

V6–v9 do not add SQL tables beyond the managed-machine and port-ownership changes;
they extend the encrypted payload contract in the PostgreSQL example. Custom
adapters must preserve intent, typed outcomes, deduplication, claims, command slots
and tombstones through every transaction. See the shared store contracts and
[recovery](recovery.md) before advertising capability flags.

## Account for retained work

Budget retained machines, disks and mapped ports after commands finish; release
requires explicit deletion and verified absence. Missing or uncertain machines
still retain their reservations. Background launch confirms a PID, not final exit
status. Follow [Persistent machines](persistent-machines.md) and
[Long commands](long-running-exec.md) before enabling these operations.

Unknown launches and disconnected terminals can block further commands. Use the
feature's resolution procedure without inventing an outcome or replaying work.
Startup and background processes can change files outside a managed command;
collection is not an atomic filesystem snapshot. File roots authorize lexical
paths and do not establish symlink containment.

## Checkpoints and worker rollback

Keep existing checkpoint approvals pinned to their captured worker version,
platform, architecture, artifact digest and resource profile. A 1.16.1 checkpoint
must not be relabeled 1.17.0 to satisfy default selection. Retain a matching worker
or separately prepare and qualify a new checkpoint. New image-only features do
not expand the supported idle, offline checkpoint contract.

Rolling back just the Elixir dependency is unsafe after v5–v9 writes: finished
executions and deleted machine tombstones still need newer readers. Disabling new
features or deleting machines does not remove this boundary. Do not strip policy
or intent fields to make records resemble an older schema.

Prefer fixing forward. Any planned backup restore must coordinate controllers,
worker requests, machine disks and artifact storage with the restored store;
restoring the database alone can lose ownership history and permit duplicate work.
Keep uncertain resources quarantined until reconciled using verified evidence.

## Feature guides

- [Persistent machines](persistent-machines.md): ownership, lifecycle and retention.
- [Port mappings](port-mappings.md): worker-wide reservations and inbound services.
- [Long-running/background exec](long-running-exec.md): budgets and launch evidence.
- [Interactive terminals](interactive-terminals.md): transport, exit and uncertainty.
- [Startup workloads](workloads.md): immutable startup and console limitations.
- [Guest files](guest-files.md): approved roots, budgets and buffered transfers.
- [Compatibility](compatibility.md): actual runtime evidence and platform limits.

For upgrades from 0.1.2 or earlier, also review the historical
[v2 transition](recovery.md#upgrading-to-0-1-3). The coordinated upgrade to 0.2.0
must account for those older records and keys as well.
