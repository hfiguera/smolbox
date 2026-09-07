# Resource qualification in progress

No hard production execution profile is certified. The library rejects requested
CPU-time, host-RSS, process-count and host-disk-byte controls. Its development
profile declares guest allocations and controller admission reservations. A
matching worker API reply is not proof of enforcement.

## Disk template mismatch in SmolVM 1.14.1

Pinned source is `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`. The released Linux and
macOS installations supply a 20 GiB storage template and a 10 GiB overlay
template. `src/storage.rs` opens requested disks, then `ensure_formatted` copies
an available template. `src/disk_utils.rs:copy_disk_from_template` only extends a
copied file when it is smaller than the request. It never shrinks it. Existing
larger disks also remain unchanged. Packed VM templates can impose further floors.

A real 1-vCPU, 256-MiB, 1/1-GiB Python machine on each platform reported those
requested allocations through the API, but `/workspace` exposed
21,118,275,584 filesystem bytes. The Linux VM had a 21,474,836,480-byte storage
raw disk and a 10,737,418,240-byte overlay raw disk. These were sparse files;
logical capacity and allocated host blocks are different measurements. macOS
had the same released template sizes and guest filesystem capacity. Neither
API matching nor sparse initial allocation justified the former 2 GiB reservation.

`WorkerConfig.allocation_floor` is therefore a required trusted declaration:
`%{storage_gb: ..., overlay_gb: ..., host_overhead_mb: ...}`. The host must verify
the largest runtime/artifact template and VMM requirement for every artifact in
that worker catalog. Requests below any floor are rejected before acceptance.
Recovered prepared work rechecks current approval before dispatch. A corrected
floor never rewrites a stored profile or authorizes command replay. Floors have
no implicit default, and configuration cannot remotely attest their accuracy.

The examples now request and reserve 20/10 GiB disks explicitly. Profiles and
machine codecs accept 1..64 GiB per disk; the old 8 GiB ceiling could not represent
the released templates. Smaller profiles are only appropriate after verifying
smaller templates on a separately qualified installation. SmolBox neither
rewrites images nor provisions worker storage. Shared caches, extracted layers,
logs, filesystem metadata and unrelated workloads require separate accounting
and host quotas. An artifact/runtime upgrade requires repeating qualification.

## Linux memory and cgroup observation

A fresh private worker was launched as an owned user-systemd unit with delegation,
2 GiB memory, no swap, 200% CPU quota and 128 host tasks. Both the unit invocation
and actual kernel control files were verified. Its one neutral VM was observed
in its own `vm-PID` cgroup with a 1 GiB memory cap and a one-core CPU quota. The
VMM's 1024 local task cap inherited the stricter parent limit of 128. Guest
processes do not each correspond to host cgroup tasks.

The selected upstream non-CUDA Linux calculation adds 768 MiB to guest memory.
Cgroup creation/writes are best-effort upstream: failure can still boot a VM.
macOS does not implement these cgroup controls. The updated example allowance
is not an automatic attestation that cgroups exist, nor a universal RSS limit.

One bounded probe attempted to allocate at most 384 MiB inside the 256-MiB guest.
The child exited with signal 9; guest kernel output identified that same Python
process as an OOM victim. The command parent and VM survived. The host unit and
VM cgroup reported no OOM events; observed peaks were 514,179,072 and 363,044,864
bytes respectively. This is evidence for that guest-memory experiment, not a
complete hostile-workload qualification or proof of host OOM containment under
all conditions. No disk-fill or process-exhaustion experiment was run.

The probe also observed one guest CPU/affinity, no host test sentinel in its
environment, no rollout token, and no host qualification workspace path. These
checks do not establish that every control-plane route or credential is isolated.
Both probe VMs were stopped/deleted only after comparing their full recorded
creation evidence, and subsequent inspection observed absence. The owned Linux
unit was stopped after verifying its invocation ID and empty inventory. No
unrelated service or VM was stopped.

## Measured durable-host workload

The repeatable benchmark in `examples/durable_host/scripts/benchmark.exs` uses
the actual PostgreSQL store, directory adapter, prepared Python artifact and
managed runtime. Each sequential submission stages the example source and three
binary input bytes, captures 13 stdout bytes, collects four artifact bytes and
verifies the guest count marker and owned-VM absence. The profile reserves one
slot/vCPU, 256 MiB guest memory plus 768 MiB overhead, and 20/10 GiB disks.
Twenty sequential samples were collected per host, with no cache clearing.

| Observed latency, seconds | macOS arm64 | Linux x86_64 |
| --- | ---: | ---: |
| Outcome median | 1.399 | 1.300 |
| Outcome p95, nearest rank | 1.559 | 1.331 |
| Outcome maximum | 3.620 | 1.414 |
| Through cleanup median | 1.607 | 1.580 |
| Through cleanup p95, nearest rank | 1.771 | 1.639 |
| Through cleanup maximum | 3.830 | 1.724 |

The macOS host was an Apple M4 Max with 128 GiB memory and 16 online schedulers;
its PostgreSQL 16.15 database was on the Linux host through a private SSH-forwarded
Unix socket. Linux used an Intel i5-1135G7, eight online schedulers and roughly
62.4 GiB OS-reported memory, with PostgreSQL through a local private Unix socket.
Both used Elixir 1.20.4/OTP 28.5 and SmolVM 1.14.1/libkrun. The different machines
and database paths prevent attributing differences to the OS or hypervisor.
The macOS outlier was the second sample, with 2.832 seconds in the start request;
its cause was not established and the sample is retained.

Median preparation/execution/collection/cleanup stage durations were
1,043.5/102/121/174 ms on macOS and 964/146.5/101/222.5 ms on Linux. Preparation
includes machine creation, start, uploads and input verification; execution
includes the controller/transport path around the guest command. These stage
times are not pure guest CPU time or VM boot time. Observed outcome polling uses
25 ms and cleanup polling 100 ms. The instrumented example uses a 50 ms runtime
poll interval, four active controller tasks, four pending queue positions and a
1,024-event telemetry bound. Database, observer and instrumentation costs are
included; these are small development-host measurements, not a production SLA.

The burst trial occupied the one VM slot for four seconds, admitted four queued
requests and rejected four further offers. Accepted queue waits were 4.461–9.714
seconds on macOS and 4.175–9.174 on Linux. Each accepted command had one instrumented
transport invocation and one guest count marker. These are qualification checks,
not worker-side acceptance receipts. A preparation failure performed no exec;
cancellation after output retained an unknown outcome and one reservation
(1 vCPU, 1,024 MiB, 30 GiB) until verified cleanup after about 66 seconds.

A finite 512 KiB producer also completed while its managed caller waited two
seconds before observing the result. Across trial phases, the largest sampled
supervised-process mailbox was two messages on macOS and one on Linux; sampled
supervised-process memory peaked at 614,928 and 502,600 bytes respectively. These
100 ms samples can miss peaks and exclude nested linked request tasks. Whole-BEAM
memory, which includes the Repo, HTTP pools, binaries and instrumentation, peaked
at 82,101,593 and 71,236,928 bytes respectively. They are not host/worker RSS limits
or a proof against an unlimited producer. Telemetry reported no dropped/timed-out
deliveries. All trial reservations were released and both worker inventories
were verified empty. See `docs/evidence/phase8-benchmarks.json` for sample data,
source hashes, native artifact identities and report checksums.

These workers and their host page caches had already been used. Pinned source
uses shared pack extraction on Linux and per-machine extraction on macOS; that
does not turn the first measured submission into a cold-host experiment. Fresh
isolated worker-state/cache-miss and cold-host measurements remain pending.

## Remaining evidence

Required work includes bounded CPU/process/disk/output stress under independently
verified host quotas, macOS resource qualification, server-side buffering and
quota-controlled slow-reader measurements, broader credential/control-plane
tests, cold-state measurements and actual protected release-worker jobs. Finite
output/path probes and the workload above cover specific behavior; passing them
does not substitute for exhaustion/isolation experiments. The implementation plan
keeps minimal-profile certification unchecked.
