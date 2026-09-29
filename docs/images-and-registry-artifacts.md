# Images and registry artifacts

Registry sources let a retained machine fetch an approved environment without an
operator copying the prepared file to each worker first. Provisioning still has a
durable identity, an approved worker and profile, and an explicit lifetime.

These operations support smolvm 1.19.0 and 1.20.2. The three operations
have different storage and authentication boundaries:

| Operation | Where the content is fetched | Identity |
| --- | --- | --- |
| Registry `.smolmachine` creation | Worker host blob cache, then machine preparation | Platform manifest digest plus prepared file content digest |
| OCI creation | Registry probe on the host; container content pulled inside the VM | Approved OCI platform manifest digest |
| Machine image list/pull | An existing machine's image storage | Observed configuration digest, or `packed` for imported images |

An image list is not a worker-wide artifact catalog. It does not enumerate the
host's prepared artifact cache.

## Approve an immutable source

Use an explicit registry, repository and lowercase SHA-256 reference. Resolve tags
and select the platform manifest before registering an approval. The constructors
do not resolve tags or inspect registry manifests. The operator must verify that
the supplied digest names the intended platform manifest, not an OCI index, and
that its content and architecture match the approval.

```elixir
{:ok, source} = SmolBox.Source.registry(
  id: "project-environment-v1",
  reference: System.fetch_env!("APP_MANIFEST_REFERENCE"),
  content_sha256: System.fetch_env!("APP_ARTIFACT_SHA256"),
  architecture: "x86_64"
)
```

`APP_MANIFEST_REFERENCE` has the form
`registry.example.com/team/app@sha256:<64 lowercase hex digits>`.
`APP_ARTIFACT_SHA256` contains just the 64 hex digits of the `.smolmachine` file's
SHA-256. The two digests identify different objects. SmolBox checks the warm
response against the approved content digest before dispatching creation.

Use `Source.oci/1` for an OCI image, with `:id`, `:reference` and `:architecture`.
Use `Source.local/1` for a prepared worker file, with `:id`, `:path`, `:sha256` and
`:architecture`. Existing artifact maps, string path constructors and checkpoint
approvals remain supported. File staging's `ArtifactStore` is unchanged.

## Register and create a retained machine

Add the remote source to `SmolBox.Runtime.WorkerConfig.new/1` with
`sources: [source]`. A worker may use `artifacts: []` when remote sources are
configured. Its architecture must match the source. Continue declaring exact
profiles, admission capacity and allocation floors that cover the actual templates
and VMM overhead. An artifact response cannot attest these host limits.

The source approval matches the complete immutable identity, including its exact
registry and repository. It does not authorize another tag, manifest or repository.

```elixir
{:ok, spec} = SmolBox.ManagedMachineSpec.new(
  scope: "my-application",
  id: "workspace-42",
  artifact: SmolBox.Source.artifact(source),
  profile: approved_profile
)

{:ok, handle} = SmolBox.Machines.create(runtime, spec)
{:ok, machine} = SmolBox.Machines.await(runtime, handle, 120_000)
```

Check `machine.state` before continuing. `await/3` also returns blocked recovery
states. Registry creation records `:preparing` intent before warming, persists a
typed `machine.preparation` result, and records `:dispatching` before creation.
The preparation and create requests share the profile's preparation deadline;
the worker client has its own operation limit as well. Caller wait timeouts change
neither deadline nor machine retention.

Start and run commands through the existing managed APIs. Every command uses the
machine's exact artifact identity and profile. Commands do not delete the machine
or release its reservation. Explicit deletion still requires verified absence.
Remote provisioning is currently a retained-machine operation; disposable
`SmolBox.submit/2` keeps its local-artifact and checkpoint workflows.

## Networking and authentication

Registry artifact downloads occur on the **worker host**. Guest networking can
remain offline, but it does not restrict host registry traffic. Host operators own
registry routing, mirrors, redirects, TLS trust, access controls and host egress.
The artifact warm endpoint must be reachable through the worker's protected
listener or proxy; exposing it publicly is not required.

OCI creation requires an explicitly approved `SmolBox.NetworkPolicy` that permits
the registry, authentication and content download destinations. Offline OCI
creation is rejected locally. SmolBox never adds allowed hosts or enables
networking to make a pull succeed. An allowlist is not proof that every registry
redirect or download destination will be reachable.

Prepared registry sources can include `credential_ref: "project-reader"`. Configure
the worker with `registry_credentials: {MyRegistryCredentials, host_context}`.
That module implements `c:SmolBox.RegistryCredentials.fetch/2` and returns
`{:ok, current_identity_token}` or an error. SmolBox persists the safe reference,
not the token. It resolves the current token for each bounded operation, so token
rotation does not change the source identity. Resolver errors are redacted.

Omitting the reference uses upstream's operator-configured registry credentials.
An explicit identity token is supported for registry artifact warm/create only;
upstream rejects its use with private or loopback registry targets. OCI creation
and machine image pulling have no matching per-request token field. They use
upstream's guest registry configuration. Worker API credentials, registry
credentials and workload secrets are separate mechanisms.

## Managed image operations

Register the target OCI source in the assigned worker's `sources` independently
of the machine's creation source. Managed pulls require a machine originally
created from OCI. On prepared `.smolmachine` machines, upstream returns synthetic
`packed` metadata instead of downloading the requested image. SmolBox rejects that
managed use before dispatch; checkpoints are also unsupported.

Start an OCI machine explicitly, then submit:

```elixir
{:ok, pull} = SmolBox.Machines.pull_image(runtime, machine_handle, "install-image-1", oci_source)
{:ok, execution} = SmolBox.await(runtime, pull, 120_000)
%{state: :completed, evidence: :image_pulled, result: %SmolBox.Image{} = image} = execution
{:ok, idle_machine} = SmolBox.Machines.await(runtime, machine_handle, 5_000)
{:ok, inventory} = SmolBox.Machines.list_images(runtime, machine_handle)
```

Each pull has its own scoped execution ID, immutable `ImagePull` intent, deadline
and typed result. Identical submissions return the original execution; conflicting
intent under the same ID fails. The machine retains its original creation source
and reservation. Pulling does not select a new workload or replace the guest root.

Pulls share the atomic active-operation slot with commands, terminals and their
file staging/collection. Stop, delete and competing work reject a busy slot, even
across controllers. Managed pulls require a running machine and an explicit network
profile. Ownership and current approvals are checked before dispatch.

The profile's `execution_ms` bounds observation. Cancellation before dispatch can
release the slot. After dispatch, cancellation, timeout, a failed response or
controller loss leaves an unknown outcome and blocks reuse. No automatic replay
occurs. Operator quiescence and `Machines.resolve/4` are required. Listing an image
does not prove an earlier request finished and cannot resolve that uncertainty.
Passive listing may run during other operations and never starts the VM.

## Image observations and low-level operations

`Client.prepare_artifact/3` returns `ArtifactPreparation` with manifest and content
digests, reported size and cache status. A warm cache still requires the registry
manifest to be fetched. Upstream checks downloaded bytes but does not rehash cache
hits; the operator must protect cached artifacts from modification.

`Client.list_images/2` returns `ImageInventory`. Its `:empty_or_unavailable` status
cannot establish that a cache is empty: smolvm returns the same empty response
when the VM is stopped. Listing does not start it. `Image.digest_kind` distinguishes
a configuration digest from the literal `packed`; neither is the manifest digest
used for source approval or evidence about mutable machine files.

`Client.pull_image/3` accepts an approved OCI `Source`. It may start a stopped
machine upstream. Low-level callers must verify ownership and serialize this
mutation with other work themselves. A successful pull does not select a different
machine workload. Never interpret an observation's reference as approval to pull it.
On prepared-artifact machines, the synthetic `packed` response is rejected because
it does not prove that the requested OCI image was downloaded.

## Recovery and resource accounting

The store serializes remote creations per worker because upstream cold pulls can
share a partial download file. This exclusion survives controller loss and worker
lease expiry. All controllers and physical workers sharing that cache must use
the same worker identity and store authority. CLI mutations and independent stores
cannot participate in this guarantee.

A lost warm or create response is not a signal to replay the operation. Keep the
original handle and inspect its record. A durable `:prepared` result permits the
controller to continue creation with that same source and remaining deadline.
Interrupted `:preparing` or `:dispatching` work stays blocked. A machine observed
only by its name is never adopted.

Recovery uses the existing explicit `Machines.resolve/4` path after operator
quiescence and verified machine evidence. Quiescence includes outstanding registry
downloads and worker requests, not just a stopped VM or an expired store lease.
Absent machines are not recreated under their old identity. Deleted tombstones
retain source identity and preparation evidence for deduplication.

Machine reservations account for requested disks and declared allocation floors,
including stopped or uncertain machines. They do **not** include shared blob cache
bytes, partial downloads or temporary extraction space. Operators must manage
those host storage budgets separately. Upstream may retry interrupted transfers
and retain partial files. SmolBox neither retries an uncertain preparation nor
deletes shared cache files. Reprovisioning from an image cannot recover files lost
from a machine's persistent disks.

## Persistence and upgrades

Remote source records use codec v10 and require the store capability
`registry_sources: 1`. This includes the atomic preparation exclusion, immutable
source identity, preparation evidence and deleted history. The memory adapter
and PostgreSQL example implement the contract. The PostgreSQL example uses its
existing encrypted payloads, partition transaction and worker index; no new SQL
migration is needed for this capability.

Managed pulls require `managed_images: 1`, codec v10 for `ImagePull` and `Image`,
`:image_pulled` completion evidence and the existing atomic command slot. Run the
shared `SmolBox.Store.ImageContract` alongside `SourceContract` when implementing
an adapter. These contracts are repository test support, not production modules.

Upgrade every controller and adapter sharing the store before enabling remote
sources. Old local/checkpoint encodings and fingerprints remain unchanged; older
machine records gain `preparation: nil` when read. Old envelopes cannot contain
remote semantics. An older release cannot read v10 records, including deleted
tombstones, so rollback requires retaining a compatible reader or an explicit
operator-controlled data migration. Do not erase history to make rollback pass.

## Runnable example

The [durable registry example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#registry-artifacts-and-machine-images)
uses PostgreSQL and separate BEAM invocations. It preserves a guest file across
recovery and stop/start, then verifies deletion and reservation release. Its OCI
mode also demonstrates a managed pull of a different image. It consumes existing
registry sources; it does not build or publish them.

The [1.20.2 qualification](runtime-1.20.2-qualification.md) records the newer
worker campaign separately from the original feature evidence above. Preserve the
exact capture runtime on checkpoint approvals; changing a filename or version
field does not migrate saved machine state.
