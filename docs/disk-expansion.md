# Grow a retained machine's disks

A project can outgrow its initial disk allocation without needing a new machine.
SmolBox can grow the storage disk, overlay disk, or both on an idle stopped or
created managed machine. The first version supports smolvm **1.20.2**, with
absolute target sizes from **1 to 64 GiB per disk**. It never shrinks a disk,
resizes CPU/RAM, automatically stops a machine, or starts it after growth.

Checkpointable machines, machines restored from checkpoints, branch children and
sources with branch history are unsupported. Their saved geometry and backing
relationships require separate qualification. Ordinary prepared and OCI machines
retain the same creation source, workload, ports and command profile.

## Stop, grow, start

Given an existing running machine handle and runtime:

```elixir
{:ok, machine} = SmolBox.Machines.inspect(MyApp.Sandboxes, handle)
{:ok, _} = SmolBox.Machines.stop(MyApp.Sandboxes, handle, machine.version)
{:ok, %{state: :stopped} = stopped} =
  SmolBox.Machines.await(MyApp.Sandboxes, handle, 60_000)

{:ok, _accepted} =
  SmolBox.Machines.expand_disks(
    MyApp.Sandboxes,
    handle,
    "project-storage-v2",
    stopped.version,
    storage_gb: 8,
    overlay_gb: 4
  )

{:ok, grown} = SmolBox.Machines.await(MyApp.Sandboxes, handle, 60_000)
:completed = grown.disk_expansions["project-storage-v2"].state
IO.inspect(grown.disk_sizes)
IO.inspect(grown.reservation.disk_gb)

{:ok, _} = SmolBox.Machines.start(MyApp.Sandboxes, handle, grown.version)
{:ok, %{state: :running}} = SmolBox.Machines.await(MyApp.Sandboxes, handle, 60_000)
```

The example's pattern matches intentionally stop on uncertainty; production hosts
should display the recorded error and follow recovery below. A stale machine
version rejects acceptance without sending a resize. Reinspect before deciding
whether a new request is appropriate. Once accepted, retry the **same operation ID,
original version and options** to recover its history. Reusing that ID with a
different request is an identity conflict. Omitted disk targets keep their current
verified size; at least one disk must grow.

History is scoped to the machine, persists after deletion, and holds up to 32
expansions. It is never evicted to allow ID reuse. `await/3` timing out stops only
the caller's wait. There is no automatic replay or retention expiry.

The machine's creation specification, fingerprint and `created_machine` evidence
remain immutable. `disk_sizes` records verified current geometry, while
`disk_expansions[id]` records intent and outcome. Commands still use the original
artifact and profile; their own ownership evidence includes the verified larger
disks. Lifecycle operations, logs and measurements likewise verify current sizes.
Unexpected size changes outside managed history remain an ownership conflict.

## Capacity and exclusion

Acceptance is an atomic store transaction. It checks the inspected version,
machine operation slot, worker disk capacity and durable drain mode before saving
intent and the full increased reservation. Competing controllers cannot spend the
same disk budget. A draining worker rejects new growth; duplicates of existing
requests return their history and already accepted work may continue.

Start, stop, delete, commands, PTYs, file transfers within commands, exports and
other expansions cannot overlap an active expansion. The operation never releases
CPU, memory, slot or retained disk reservations merely because a machine is stopped.
Export helper resource floors use the expanded disk sizes.

These are reservations, not actual host free space or filesystem quotas. The host
must provide enough storage and functioning filesystem tooling. Configured limits
and allocation floors remain operator responsibilities.

The worker changes disk files while stopped. Guest filesystem growth happens on
boot and may finish after the machine first reports running. Verify usable space
inside the guest before starting a workload that needs it. A successful stopped
resize is not application readiness or a guest filesystem measurement.

## Uncertainty and recovery

The controller persists dispatch intent before sending HTTP. Only the process
receiving a successful resize response followed by a matching observation completes
that request. After an interrupted dispatch or a lost response, it records an
unknown outcome and never resends the mutation automatically. Failure to establish
safe ownership before dispatch also leaves blocked evidence for operator review.

Upstream can expand one disk before the other fails, and its database update
happens after physical disk growth. An error or old size observation cannot prove
that neither disk changed. SmolBox therefore retains the complete target reservation
and blocks ordinary reuse. A controller restart, a stopped observation, or an
empty worker list does not establish quiescence.

To retain the machine:

1. Stop old controllers and fence their outstanding worker requests. Coordinate
   every client with access to the worker and preserve exclusive namespace control.
2. Verify the original owned machine and its actual disk files. If only part of
   the request completed, deliberately repair both disk files and worker metadata
   to the complete target sizes. This is an operator action, never automatic replay.
3. Keep the machine stopped. Inspect the current managed version and resolve:

```elixir
{:ok, blocked} = SmolBox.Machines.inspect(MyApp.Sandboxes, handle)
{:ok, resolved} =
  SmolBox.Machines.resolve_disk_expansion(
    MyApp.Sandboxes,
    handle,
    "project-storage-v2",
    blocked.version,
    quiesced: true
  )
:resolved = resolved.disk_expansions["project-storage-v2"].state
```

Resolution verifies the owned stopped machine and complete target geometry. It
keeps the larger reservation and preserves the original uncertainty in history:
`:resolved` is different from `:completed`. Store fencing cannot retract HTTP
requests already sent; `quiesced: true` is a host assertion, not a remote fence.

Alternatively, after quiescence, explicitly remove the owned machine and call the
same API with `disposition: :deleted`. It must verify absence before releasing the
reservation. It sends no delete request and keeps the operation identity in history.
Generic `Machines.resolve/4` cannot bypass an active expansion.

## Client API

Hosts managing lifecycle themselves can supply a previously inspected
`SmolBox.Machine` to `SmolBox.Client.expand_disks(client, observation, options)`.
The client checks the pinned runtime, stopped/created state, ownership fields and
nondecreasing sizes before posting to `/api/v1/machines/{name}/resize`. It validates
the response but does not provide durable intent, reservations or recovery.

Exclusive lifecycle control is required: upstream can resize a running machine,
and the stopped request has no atomic stopped-state precondition. Another direct
API client must not start or replace it between verification and mutation. The
managed API serializes SmolBox operations through the store; it cannot fence an
uncoordinated external client.

## Persistence and upgrades

Adapters advertise `managed_disk_expansion: 1` and implement `:expansion_accept`
and `:expansion_advance` under the existing `Store.machine/3` boundary. Acceptance
must serialize with all worker capacity updates and drain changes. Run the shared
`SmolBox.Store.ExpansionContract` against the adapter's actual transaction system.

Expansion histories and commands on expanded machines selectively use **codec v14**.
Old records decode with empty history and retain their previous wire encoding.
Upgrade every reader, controller and resource projection writer before accepting
expansions. Older readers cannot decode v14 records, even after deletion. Rolling
back while that history remains requires compatible readers; deleting it is not
a supported migration strategy.

The PostgreSQL example needs **no additional SQL migration for disk expansion**;
it updates encrypted payloads and existing reservation columns in one transaction.
Its worker-control migration from durable draining is still required. The memory
adapter remains ephemeral. This feature does not turn in-memory storage durable.

## Runnable Linux walkthrough

Configure the durable example's worker, PostgreSQL, encryption/fingerprint keys,
artifact directory and approved Python artifact as described in its README. Use a
fresh execution ID and store partition, then run from `examples/durable_host`:

```sh
mix ecto.create
mix ecto.migrate
mix run -e 'SmolBox.DurableHost.DiskExpansionDemo.run("prepare")'
mix run -e 'SmolBox.DurableHost.DiskExpansionDemo.run("resume")'
```

`prepare` creates a 2/2 GiB machine, writes a file, records filesystem sizes, stops
it and grows it to 4/3 GiB. It intentionally leaves the stopped machine retained.
`resume`, in a separate BEAM process using the same keys and database, starts that
same machine, verifies the file and both larger guest filesystems, stops it and
explicitly deletes it. It verifies worker absence and reservation release. A failed
walkthrough leaves its record and resources for inspection rather than discarding
evidence automatically.

This scenario passed on physical Linux x86_64 with smolvm 1.20.2 and PostgreSQL;
see the [recorded validation summary](evidence/disk-expansion-linux.json).
Memory and PostgreSQL conformance tests cover concurrent capacity admission,
deduplication, drain exclusion, partial outcomes, retained reservations and codec
compatibility. Simulated controller tests cover restarts, no replay, mismatched
ownership, explicit resolution and commands after growth. No macOS VM qualification,
checkpoint/branch expansion, live growth or out-of-space fault campaign is claimed.
