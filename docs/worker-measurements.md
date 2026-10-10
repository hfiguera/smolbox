# Machine measurements and worker capacity

A reservation answers “what have we promised?” A measurement answers “what did
this worker observe?” SmolBox exposes both without using idle CPU or free memory
to undo a durable reservation.

These APIs are additive. They require no store migration, codec change or new
adapter callback. Existing `SmolBox.workers/1`, admission, retention and cleanup
keep their behavior. Wire measurements are qualified against smolvm 1.20.2 and 1.22.0;
older workers can omit optional fields or reject endpoints.

## Observe a machine

For a retained handle returned by `SmolBox.Machines.create/2`:

```elixir
{:ok, measurement} = SmolBox.Machines.measurements(MyApp.Sandboxes, handle)
IO.inspect(Map.take(measurement, [:cpu_millis, :rss_mb, :pss_mb, :disk_used_mb]))
```

The API reads the durable assignment and verifies the recorded machine incarnation
against the same response that supplies the counters. It takes no command slot,
can run alongside active commands and never starts a stopped machine. A missing
machine, worker failure or ownership mismatch is an error, not zero usage. It does
not resolve an unknown command or prove that a deletion completed. Your application
must authorize access to the handle's scope.

If your application owns machine lifecycle directly, use
`SmolBox.Client.machine_measurements(client, name)`. It verifies the requested name,
not durable ownership. Existing `Client.inspect_machine/2` still returns only a
`SmolBox.Machine`; changing measurements never become identity evidence or durable
execution data.

| Field | Meaning | Important limit |
| --- | --- | --- |
| `cpu_seconds`, `cpu_millis` | Cumulative CPU consumed by the current VMM process | Counters reset on process restart; neither is a CPU percentage |
| `rss_mb` | Host process resident memory in MiB | Summing branch RSS can count shared pages repeatedly |
| `pss_mb` | Proportional resident memory in MiB | Available where the host supports PSS; useful for shared branch pages |
| `private_memory_mb` | Private resident memory in MiB | Host process memory, not guest free memory |
| `shared_memory_mapped_mb` | Shared memory mapped by this process in MiB | Not a unique physical memory total |
| `disk_used_mb` | Host blocks allocated for machine disks in MiB | Not free guest space, configured disk capacity or a complete artifact inventory |
| `egress_bytes` | Cumulative guest outbound bytes reported by virtio-net | May be missing or delayed; no inbound total or rate is supplied |

Missing or null counters stay `nil`. A reported zero stays zero. Stopped machines
can retain disk measurements while process counters disappear. `checked_at_ms` is
the controller receive time; upstream supplies no per-counter sample timestamp.
Counters can be stale or reset, so these snapshots are unsuitable for billing.

## Compare reservations and usage

```elixir
{:ok, workers} = SmolBox.workers(MyApp.Sandboxes)
worker_id = hd(workers).id
{:ok, report} = SmolBox.worker_report(MyApp.Sandboxes, worker_id)

IO.inspect(report.worker.capacity, label: "Configured admission limits")
IO.inspect(report.reserved, label: "Durable reservations")
IO.inspect(report.remaining, label: "Reservation headroom")
IO.inspect(report.observed_capacity, label: "Worker utilization")
IO.inspect({report.usage_error, report.capacity_error}, label: "Read errors")
```

The store already accounts for retained machines, checkpoint and export files,
branches and their helper resources. This report uses that same accounting.
`remaining` is configured capacity minus reservations, clamped at zero. It is not
host free capacity. Stopping a machine does not imply all of its reservations can
be released; retained disks and uncertain outcomes remain accounted for.

A store error leaves `reserved` and `remaining` unavailable. A worker error leaves
`observed_capacity` unavailable. Each error is independent; neither is replaced by
zero or inferred from the other. Reads are not atomic across worker, store and
controller. The cached worker status carries its own `health_checked_at_ms`.

`observed_capacity` is a `SmolBox.WorkerCapacity`:

- `allocated_cpus` and `allocated_memory_mb` cover running VM allocations.
- `used_cpus` is fractional CPU cores, so `0.25` means a quarter core.
- `used_memory_mb` is summed RSS. Optional PSS, private and shared mapped fields
  distinguish actual sharing; shared mappings are not a unique total.
- Optional `host_memory_total_mb` and `host_memory_available_mb` describe the
  effective host/cgroup memory ceiling and availability reported by upstream.
- `used_disk_gb` is upstream's integer disk usage gauge. It does not inventory every
  checkpoint, export, registry cache or backing file, and does not report free disk.
- `boot_id` identifies a serve process. A change alone does not prove that a guest
  stopped, a disk vanished or a reservation can be released.

The capacity GET has a maximum 500 ms operation budget and 8 KiB response limit,
further limited by client settings. It runs on the caller, outside the coordinator.
Store reads retain the adapter's normal timeout contract. No polling starts
implicitly; the host decides whether and how often to refresh reports.

## Explain a new request

Pass the same valid `SmolBox.ExecutionSpec` or `SmolBox.ManagedMachineSpec` you
would use to submit a disposable execution or create a retained machine:

```elixir
{:ok, reports} = SmolBox.admission_report(MyApp.Sandboxes, spec)

Enum.each(reports, fn report ->
  IO.inspect({report.worker.id, report.required, report.blockers})
end)
# Example: {"worker-a", %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 30},
#           [{:capacity, :disk_gb}]}
```

Required resources include profile host memory overhead and both configured disks.
Reports identify health/drain status, unsupported specifications, unavailable store
accounting and individual resource shortages. They send no worker request and
create no record or reservation.

An empty blocker list is advisory, not permission to run. Another controller can
reserve capacity immediately afterward. The existing atomic store reservation is
still authoritative. Queue limits, duplicate identity conflicts, port claims and
artifact preparation can also affect acceptance. Managed commands, branch creation,
checkpoint capture and exports use other reservation rules and are not assessed
by this API. Low observed CPU/memory never increases admission headroom.

## Prometheus text and draining boundaries

With an approved `SmolBox.Client` from the [client guide](client.md):

```elixir
{:ok, capacity} = SmolBox.Client.capacity(client)
{:ok, prometheus_text} = SmolBox.Client.metrics(client)
```

Both use the client's configured operation and response limits. Metrics returns
bounded UTF-8 Prometheus text without interpreting names or starting a scraper.
The host owns scheduling, storage, access control and any export to monitoring
systems. Worker reports and raw metrics are operator data, not tenant APIs.
SmolBox's [lifecycle telemetry](telemetry.md) remains separate from worker metrics.

[Durable worker draining](worker-draining.md) persists admission mode across
controllers sharing a capable store. It gates new reservations, not requests
already sent or work on existing assignments. Use maintenance reports and explicit
versioned resume for operator workflows. Upstream `/drain` stops running machines
across the worker; these APIs never call it.

## Validation

Field availability and metric accuracy depend on the worker and host. Passing
decoder tests does not establish live counter accuracy or hard resource enforcement.
See [Measurements and worker capacity tests](worker-measurements-validation.md)
for simulated checks, the recorded Linux run and its unavailable counters.
