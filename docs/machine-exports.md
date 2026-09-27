# Export a stopped machine

An export turns a prepared machine into a reusable registry artifact. Install your
tools, write configuration, stop the machine, and export its supported disk state.
A second machine can then start from that artifact with a new managed identity.

Export is **not a checkpoint or a live branch**. It does not preserve memory,
running processes, open connections, or every mounted path. It does not provide
backup scheduling, disaster recovery, migration, or automatic registry cleanup.

## What smolvm 1.19.0 preserves

SmolBox uses `POST /api/v1/machines/:name/export` on the approved 1.19.0 worker.
It requires a stopped machine and never stops one implicitly.

| Source | Supported exported state | Excluded state |
| --- | --- | --- |
| Container machine | Container root filesystem changes and pack configuration | `/workspace`, host mounts, temporary filesystems, memory and processes |
| Bare VM | Storage and overlay disks used by the pack exporter | Host mounts, memory and processes |

The HTTP endpoint does not expose the CLI's `--include-workspace` option. For a
container example, put the recognizable file in a persistent root filesystem path
such as `/app/export-proof.txt`, with an explicit guest path policy when staging
files there. Do not use `/workspace` to demonstrate export preservation.

Pack metadata can carry environment, entrypoint, command, working directory,
user, network settings, and secret references. Treat an artifact as potentially
sensitive. SmolBox discards the worker's returned full metadata rather than storing
it in the export record; that does not remove it from the published artifact.
Application consistency requires the application to finish its writes before
stop. Neither a digest nor a stopped observation proves application consistency.
Checkpoint sources are rejected by managed export admission.

The worker setting `SMOLVM_FILE_TRANSFER_MAX_BYTES` also overrides the pack
export read limit in 1.19.0. A small transfer cap can therefore reject a flattened
root filesystem even when ordinary commands and file transfers work. The default
pack read ceiling is 64 GiB; an explicit override replaces it. Qualify that setting
for the intended exported layer size. SmolBox's per-file upload/download policy is
a separate control and does not need to be raised to enable export. The HTTP API
does not expose this worker setting for remote preflight.

## Approve a publication destination

The host registers exact `SmolBox.ExportDestination` values through the owning
worker's `export_destinations` configuration:

```elixir
{:ok, destination} = SmolBox.ExportDestination.new(
  id: "project-exports",
  registry: "registry.example.com",
  repository: "team/project",
  credential_ref: "project-publisher",
  immutable_tags: true,
  resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
)
```

These resource numbers are illustrative approval values, not universal sizing.
`resources` is additional to the source machine's retained reservation. The export
helper uses four CPUs, a host-dependent default memory allocation, and a sparse
disk with a minimum of 64 GiB or three times the largest relevant source. Operator
overrides, packed layers, source copies, and staging can require more. Admission
checks a conservative source-profile disk floor; the host must size for actual
layers and overrides and enforce filesystem limits. Accounting is not a quota.

`immutable_tags: true` is an operator declaration that the registry rejects tag
replacement and publication uses one store authority. SmolBox cannot attest the
registry's policy. Both `tag` and `tag-linux-amd64` (or `tag-linux-arm64`) must be
unused. The store claims both names permanently, and the controller checks their
absence before dispatch. Only the registry can fence an unrelated writer racing
that check. Use a new tag for every export. Store partitions do not coordinate
publication claims with each other.

Registry requests use HTTPS with bounded responses and no redirects. An optional
`ca_cert_file` configures controller-side registry trust. The worker separately
needs appropriate registry trust and routing. `allow_insecure_loopback: true` is
an explicit option for an isolated local registry, not a production HTTP switch.
Export and registry traffic originates on the host and is not controlled by the
guest's network policy.

Configure `registry_credentials: {MyCredentials, context}` on the worker.
`MyCredentials.fetch(context, "project-publisher")` must return a current, scoped
**OCI bearer token with read and push permission**. Publication does not perform
the identity-token exchange used by artifact preparation. Keep separate publisher
and reader references when their credential contracts differ. Tokens are resolved
for each operation, never put in the destination or durable result. Protect the
worker listener, registry, and the credential resolver separately.

## Submit and inspect

After `SmolBox.Machines.stop/3` has completed and the machine is idle:

```elixir
{:ok, request} = SmolBox.ExportSpec.new(
  id: "environment-2026-09",
  destination: destination,
  tag: "environment-2026-09",
  timeout_ms: 900_000
)

{:ok, handle} = SmolBox.Exports.submit(runtime, machine_handle, request)
{:ok, export} = SmolBox.Exports.await(runtime, handle, 900_000)
{:ok, same_record} = SmolBox.Exports.fetch(runtime, handle)
```

A handle is `{scope, machine_id, export_id}`. Authorize the scope in your host;
knowing a handle is not authorization. Identical submissions return the original
handle even after source deletion. Changing the specification under that identity
returns `:identity_conflict`. Different identities that overlap an existing tag
claim are refused. Store admission failures currently use `:admission_exhausted`.
Each machine retains at most 256 export records; history is never evicted to admit
another request.

A returned `{:ok, export}` means a record was read. Inspect its `state`:

| State | Meaning | Source operation slot and extra reservation |
| --- | --- | --- |
| `:accepted` | Durable intent; worker export not dispatched | Held |
| `:dispatching` | The worker request may have been sent | Held |
| `:verifying` | Worker receipt saved; checking registry identity | Held |
| `:published` | Artifact identity verified; helper cleanup not attested | Held |
| `:unknown` | Effects or completion cannot be established safely | Held |
| `:completed` | Verified publication and operator-confirmed quiescence | Released |
| `:failed` | Failure before a potentially effective export dispatch | Released |
| `:cancelled` | Cancelled before dispatch | Released |
| `:resolved_unknown` | Operator confirmed quiescence; publication remains uncertain | Released |

The source's own reservation remains until verified source deletion. Export never
deletes, replaces, starts, or restarts that source. Commands, terminals, file
staging/collection, and lifecycle changes share the machine's exclusive operation
slot. Controllers using the same store cannot admit conflicting work while export
is active or uncertain. Direct client calls and external operators must respect
that authority; the store cannot fence requests outside it.

`await/3` returns on terminal, published, or unknown states. Its timeout ends only
the caller's wait. The request has its own timeout (one second to 24 hours, default
15 minutes), and the worker client has separate operation limits. Export provides no streaming
heartbeat: configure both `operation_timeout_ms` and `receive_timeout_ms` on the
worker endpoint to cover the approved export duration. Their ordinary defaults
are 30 seconds and 15 seconds respectively; the export request does not override
the host endpoint policy. Caller departure
and cancellation cannot stop a dispatched worker export. `cancel/2` cancels
accepted work; dispatch or verification becomes unknown. It leaves published and
terminal evidence intact. It never deletes registry objects.

## Verify cleanup before releasing the source

In smolvm 1.19.0, helper termination can fail during cleanup while the export HTTP
response still reports success. A successful response alone cannot release the
additional reservation safely. `:published` therefore keeps both the operation
slot and helper allowance until the host independently confirms quiescence.

Before resolution, fence pending requests from old controllers, confirm that the
worker's export subprocess and helper VM have stopped, and account for or remove
only this export's temporary storage. A stopped source, an expired store lease,
or a controller restart is not sufficient evidence. The HTTP API does not expose
a helper cleanup attestation; this step belongs to the operator or host integration.

Then fetch the current machine version and confirm:

```elixir
{:ok, machine} = SmolBox.Machines.inspect(runtime, machine_handle)
{:ok, completed} = SmolBox.Exports.resolve(
  runtime, handle, machine.version, quiesced: true
)
```

Resolution verifies the recorded source incarnation is still stopped. It refuses
an ownership mismatch, running source, or unavailable worker. A published export
becomes completed and retains its result. An unknown export becomes
resolved_unknown, not failed: partial or complete publication may still exist.
Do not use a new export identity to retry until the old request is quiescent;
choose a fresh tag and reconcile any existing registry objects separately.

If the operator already deleted a quiescent source, use `disposition: :deleted`
with the same confirmation. SmolBox verifies absence before releasing its source
reservation and retaining the deleted record. This does not delete the source for
you. Export resolution never removes registry data.

## Reuse the verified artifact

The worker's receipt digest identifies the **per-platform OCI manifest**, not the
tag's index or the `.smolmachine` bytes. SmolBox fetches and hashes that manifest,
fetches and hashes its configuration, checks descriptor sizes and platform, checks
both publication tags, and checks artifact blob availability. The typed result
keeps `manifest_sha256`, `config_sha256`, and `content_sha256` separate.

Verification does not download the entire artifact. It trusts the approved
registry's content-addressed storage and availability responses. Normal source
preparation verifies downloaded artifact bytes; existing upstream cache trust
still applies. These checks establish identity, not the safety of guest contents.

For a published or completed result:

```elixir
{:ok, source} = SmolBox.ExportResult.source(export.result,
  id: "project-environment-2026-09",
  credential_ref: "project-reader"
)
```

Review and explicitly register this exact source in the target worker's `sources`
approvals. `source/2` constructs a value; it does not change runtime configuration.
Omit `credential_ref` only when the existing pull authentication policy permits it.
Create a new `ManagedMachineSpec` using `SmolBox.Source.artifact(source)` and the
approved profile. Keep the source architecture, pinned 1.19.0 runtime, workload,
network, capacity, and destination requirements explicit. No universal portability
is promised. The new machine has its own identity, disks, and deletion lifecycle.

A complete three-process PostgreSQL example is available in the
[durable host example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#export-a-stopped-machine-and-reuse-its-artifact).
It separates publication, operator cleanup confirmation, and explicitly approved reuse.

## Durable restart and compatibility

Export intent is committed before worker mutation. Restarted controllers never
replay dispatching exports: they become unknown. A saved receipt in verifying
state permits read-only registry verification without another export request.
Unknown records remain blocked until explicit resolution. Registry unavailability
is not evidence of absence, and missing machines are never silently replaced.

Adapters advertise `managed_exports: 1` only after implementing the export
transactions, exclusion, permanent tag claims, and additional resource projection.
Run the shared `SmolBox.Store.ExportContract` against the adapter.

Records with export history use **codec v11**. Records without export history keep
their existing encoding. The memory adapter and shared PostgreSQL example support
v11. PostgreSQL uses the existing encrypted machine row and partition transaction;
**no new SQL migration is required**. Its history scan is intended for the example's
bounded deployments, not a large registry scheduling service.

Upgrade every controller, reader, and resource projection writer sharing a store
before enabling exports. Mixed versions are unsupported. Older releases cannot
read v11 records or account for their active helper reservations. A code rollback
after export admission requires a compatible reader or restoration of a coordinated
pre-feature backup after all worker effects are quiescent; never strip export
history or reservations to make an older reader accept them. The community example
keeps its published dependency and conditionally omits export capability there.

Export history, source-machine disks, and registry artifacts have separate
lifetimes. Deleting either source or copy leaves the published artifact and export
history intact. Registry retention and explicit artifact deletion belong to the
host; this feature adds no expiry or garbage collection.

## Validation and limits

[Recorded Linux evidence](evidence/managed-export-linux.json) covers smolvm 1.19.0
on Linux x86_64 with an Alpine container machine and zot 2.1.21. The prepare,
cleanup-confirmation, and reuse phases ran in separate BEAM processes against
PostgreSQL. The copy preserved the file, changing it left the source unchanged,
and both deletions released their reservations. A subsequent download verified
the retained artifact's byte digest after both machines were absent.

Publication used a scoped bearer test proxy in front of real zot storage. The
registry accepted an authenticated create and rejected tag replacement; the proxy
rejected an unauthenticated write. This exercises publication credentials and
immutable storage behavior, not an external production identity provider.
The existing 14 real-worker client/runtime/security tests and 25 durable Linux
recovery tests also passed against the isolated worker and PostgreSQL store.

A negative live case configured the worker's transfer cap to 1 MiB. Upstream
rejected an approximately 8 MiB flattened layer; SmolBox retained an unknown
outcome and extra reservations. After fencing the worker requests and confirming
helper/staging quiescence, explicit resolution and source deletion released those
reservations. Repeating the complete acceptance scenario with an export-capable
worker setting succeeded. The rejected request was not replayed.

Simulated HTTP and shared memory/PostgreSQL contract tests cover competing
controllers, permanent tag claims, ownership mismatches, command/terminal/file
exclusion, cancellation, deadlines, corrupt registry responses, and store failures
around dispatch, receipt, and result writes. Those fault tests are not evidence of
real power-loss durability or a production registry's failure behavior.

Export remains development-qualified. Bare VM exports and macOS exports were not
live-qualified in this campaign. Host quotas, crash-consistent application state,
universal artifact portability, and automatic helper cleanup are not certified.
