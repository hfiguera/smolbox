# Port mappings

Expose a TCP service inside a retained machine through a fixed port on its worker
host. Mappings belong to machine creation, survive controller recovery and
stop/start, and remain reserved until verified deletion. They do not belong to a
command, and command completion or cancellation does not remove them. Forwarded
connections and detached guest services do not acquire a managed command slot.
Stop/delete can interrupt their traffic; SmolBox does not drain service connections.

This requires smolvm **1.17.0** on Linux x86_64 or macOS Apple Silicon, an approved
prepared image, and a store advertising `managed_ports: 1`. Checkpoint mappings
are rejected. No-port images, disposable executions and checkpoints retain their
existing behavior. Published packages predating this feature do not include it.

## Create and use

Use the supervised runtime, approved image and profile from
[Host integration](host-integration.md). The host application must authorize the
scope and requested host ports before calling this API; a profile catalog is not
a port-authorization policy:

```elixir
alias SmolBox.{Machines, ManagedMachineSpec, PortMapping}

{:ok, mapping} = PortMapping.new(host: 18080, guest: 8000)
{:ok, spec} = ManagedMachineSpec.new(
  scope: "my-app", id: "http-001", artifact: python_artifact,
  profile: profile, ports: [mapping]
)
{:ok, handle} = Machines.create(MyApp.Sandboxes, spec)
{:ok, %{state: :created} = machine} = Machines.await(MyApp.Sandboxes, handle, 90_000)
{:ok, _} = Machines.start(MyApp.Sandboxes, handle, machine.version)
{:ok, %{state: :running}} = Machines.await(MyApp.Sandboxes, handle, 90_000)
```

Then submit commands using `Machines.submit/3`. Start your service on guest port
8000, listening on the guest network interface (for example `0.0.0.0`), and check
application readiness separately. These matches illustrate success; inspect and
handle conflicts, uncertainty and nonzero command exits in applications.

`PortMapping.new/1` accepts only integer `host` and `guest`, each 1–65,535.
Zero/automatic allocation, addresses and protocol options are rejected. A machine
can have at most 32 mappings, with unique host ports; multiple host ports may
target the same guest port. Constructors sort by host port. Order alone does not
change identity, but changing either endpoint under an existing scoped machine ID
returns `:identity_conflict`. Mappings cannot be updated on an existing machine.

Low-level callers may pass the same `ports` list to `MachineSpec.new/3` and
`Client.create/2`. That API validates requests and observations but does not reserve
ports or persist management. The caller owns scheduling, authorization, recovery
and cleanup. The low-level health API reports runtime version, not an attested
platform or binding configuration; its caller must verify the qualified deployment.
`Profile` and disposable `ExecutionSpec` do not accept port mappings;
the retained machine is the place to configure them.

## Reachability and outbound policy

The host port belongs to the **worker**, which may be a different machine or
network namespace from the Elixir application. smolvm 1.17.0 binds IPv4 loopback
by default and attempts an IPv6 loopback listener on a best-effort basis. A local
worker normally exposes the example at `http://127.0.0.1:18080` on that worker.
Guest services must listen beyond guest loopback to receive forwarded traffic.

The worker process's `SMOLVM_PUBLISH_ADDR` can select another IPv4 bind address.
`0.0.0.0` also requests an IPv6 wildcard listener; other values retain IPv6
loopback. Upstream falls back to IPv4 loopback for invalid values. This is
worker-wide deployment configuration, not a per-machine API setting or an
attested part of `Machine` observations. Review the actual worker environment
and listeners before deployment. SmolBox does not provision public URLs, tunnels,
reverse proxies, TLS, authentication, firewall rules or guest-service supervision.

Inbound forwarding uses TCP and **virtio-net**. It does not enable unrestricted
outbound access. `profile.network: :offline` remains the default and, with ports,
means denied ordinary outbound traffic while a network device exists for inbound
traffic. SmolBox explicitly sends `network: false`, `networkBackend: "virtio-net"`,
`allowedHosts: []` and `allowedCidrs: []`. Omitting the empty allowlists would let
upstream construct a permissive outbound policy when it attaches the device.
Observations must confirm those fields before SmolBox accepts the mapping.

An explicit `NetworkPolicy` remains an independent outbound allowlist and is
preserved unchanged. Upstream DNS and authenticated rollout infrastructure
exceptions still apply; see [Network access](network-access.md). Inbound replies
are necessary for forwarding and are not arbitrary guest-initiated outbound
access. A mapping is not proof of application readiness or remote reachability.

## Ownership, conflicts and recovery

The authoritative store atomically reserves `{worker_id, host_port}` along with
machine assignment before any worker mutation. Competing controllers cannot both
claim a port, and a partial multi-port conflict rolls back the complete allocation.
Use one stable identity and one shared authority for each physical worker.
Independent stores or aliases for the same worker cannot coordinate reservations.

Logical reservations are separate from operating-system listeners and from
CPU/memory/disk/slot accounting. A stopped observation can precede closure of the worker listener. A stopped VM
eventually releases its socket, but SmolBox keeps its port reservation. An unmanaged VM or another host process can still
occupy that port. SmolBox never remaps a conflict to another port or silently moves
an assigned machine to another worker.

| Situation | Result and release rule |
|---|---|
| Another managed machine owns a requested port | Atomic reservation fails with `:port_conflict`; the unassigned request becomes `:conflict`, with no new reservations or worker request. Delete that request explicitly and submit a new identity after resolving the conflict. It does not automatically try another worker. |
| Host socket occupied during start | Upstream `PORT_IN_USE` becomes a redacted `:port_conflict`; the dispatched mutation remains uncertain and all reservations stay held. |
| Rejected or lost create response after dispatch | Retain assignment and ports. A response is not proof that no create can arrive later; do not replay or adopt by name. |
| Missing machine, unavailable worker, mismatched mapping | Keep reservations and block unsafe reuse. An outage is not absence and a missing machine is not replaced with an empty one. |
| Stop/start or command completion/cancellation | Keep mappings and reservations. Unknown commands continue to block subsequent commands and conflicting lifecycle actions. |
| Explicit deletion | Release only after verified absence under the existing owned-deletion contract. Preserve the deleted identity/specification for deduplication. |
| Operator resolves absent resource | After quiescing old controllers and outstanding requests, verify absence with `Machines.resolve/4`, `quiesced: true, disposition: :deleted`; then release. |

For uncertain start, remove the external conflict, establish operator quiescence,
verify the recorded machine is stopped, and use `Machines.resolve/4` before a new
explicit start. An observed stop or store lease does not fence requests already
sent to a worker. Read [Persistent-machine recovery](persistent-machines.md#cancellation-and-uncertain-outcomes)
before asserting quiescence. Changed observed mappings never authorize mutations
against a different configuration.

## Persistence and upgrades

Managed machines and associated commands now write codec **v5**, even when their
port lists are empty. Exact v4 records load with `ports: []` and
`reserved_ports: []`; their no-port fingerprints retain their original meaning.
Old envelopes cannot contain new port fields. Disposable image/checkpoint writes
retain their v2/v3 shape. Existing persisted specifications remain unmapped. New mappings require explicit,
host-authorized creation intent; profile outbound approvals are not broadened.

1. Drain and stop every controller sharing the worker/store authority, including
   controllers that submit only disposable work. Back up records and keys.
2. Upgrade adapters and readers together. Apply existing migrations plus
   `20260923000000_managed_port_ownership` in the PostgreSQL example. No v4 payload
   backfill is required because those records cannot own ports.
3. Confirm `managed_machines: 1` and `managed_ports: 1`, restore management and run
   the HTTP acceptance example before admitting services.

PostgreSQL uses a unique `(worker_id, host_port)` key across its store partitions;
the owning partition/scope/ID is a foreign key to the machine record. Record writes,
port changes and assignment indexes share one transaction. Reads compare port
index rows against authenticated durable records; inconsistent projections fail
as store errors. Partition locks still govern leases and numerical capacity:
cross-partition port uniqueness is extra protection, not permission to run one
worker under multiple independent controller authorities. Administrative deletion
of a store partition cascades through its indexes and destroys recovery evidence;
it is not a supported live-machine cleanup operation.

Old controllers cannot read v5, and old writers cannot honor retained ports. Do
not mix versions or remove the capability while recovering mapped machines.
Rollback requires a reviewed conversion preserving identities and evidence or a
separate upgraded worker/store authority. Disabling new mappings is insufficient:
managed writes without ports also use v5. The migration refuses downgrade while
managed machines, associated commands or port owners remain.

## Runnable HTTP acceptance example

Configure the dedicated worker, PostgreSQL, approved Python artifact, private
artifact directory, partition and keys as described in the durable host README.
Use the same values for both invocations. From `examples/durable_host`:

```sh
mix ecto.migrate
export SMOLBOX_HTTP_PORT=18080
MIX_ENV=test mix run scripts/persistent_http.exs prepare
# The first BEAM exits; the VM and service remain available.
curl --fail http://127.0.0.1:18080/retained.txt
MIX_ENV=test mix run scripts/persistent_http.exs resume
```

Run where the worker listener is reachable. For an operator-provided forwarding
path, set `SMOLBOX_HTTP_URL` to its complete `/retained.txt` URL. This does not
change listener binding. Use a fresh `SMOLBOX_EXECUTION_ID` and
`SMOLBOX_STORE_PARTITION` for each new demonstration; duplicates do not replay work.

`prepare` writes a file, starts a detached Python HTTP server in a separate managed
command, verifies guest readiness and host HTTP access, and exits the controller.
`resume` recovers the same machine and mapping from PostgreSQL, reaches the existing
service, stops/starts the VM, starts the guest service again, and reads the same
file through the same host port. It explicitly deletes the VM, checks worker
absence, verifies empty port/capacity reservations, and checks post-deletion
deduplication. JSON output records those assertions. An HTTP process is not
expected to survive VM stop/start; forwarding provides no process supervision.

The example requests 2 GiB storage and 2 GiB overlay and needs a prepared image
qualified for these sizes plus a working worker `resize2fs`. Use dedicated test
ports and a private database partition. Do not run it against an unrelated service.

See [validation evidence](port-mappings-validation.md) for the tested platforms,
source/runtime identities, initial failures and cleanup.
