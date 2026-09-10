# Resource evidence and deployment boundaries

SmolBox relies on SmolVM for VM isolation and on the deployment for host resource
enforcement. Execution profiles declare guest allocations and controller admission
reservations; the supported worker qualification remains `:development`.
The library rejects requested CPU-time, host-RSS,
process-count and host-disk-byte controls; a matching worker API reply is not
proof of enforcement. See [Deployment boundaries](security.md) for the division
of responsibilities.

The original 0.1.0 experiments are retained below with their recorded settings
and outcomes. The subsequent Linux campaign adds evidence for a different,
externally constrained deployment. It does not change the library's accepted
profile options or the results of the earlier experiments.

## Subsequent Linux deployment validation

After the 0.1.0 release, we tested pinned SmolVM 1.14.1 and approved Python/Node
artifacts in a disposable Linux x86_64 VM with nested KVM. The configuration runs
one execution at a time, with no guest networking, host mounts or production
secrets. It uses a dedicated worker account, private Unix API and network
namespace, and startup checks for pinned inputs and required kernel controls.

| Worker control | Configuration and observed result |
|---|---|
| CPU bandwidth | One CPU of bandwidth; kernel throttling recorded under load |
| Charged memory | 1.5 GiB, zero swap; the kernel recorded an OOM kill at the limit and systemd stopped the worker |
| Host tasks | 96 processes/threads; the kernel rejected further task creation |
| VM/cache storage | 768 MiB tmpfs with separate 64 MiB control storage; disk exhaustion produced a write error, metadata retained space, and owned API deletion succeeded |
| Worker lifetime | 300-second deadline with five-second stop grace; the independent deadline terminated the worker during a potentially accepted execution |

These controls apply to the worker and its VMM processes inside the outer VM.
The physical host separately bounds QEMU and lab storage; the worker exhaustion
results do not establish that every outer limit was exhausted. CPU bandwidth is
not accumulated CPU time, charged memory is not per-process RSS, and host tasks
are not guest PIDs. Storage is bounded for this worker, not through a per-command
disk-quota option in SmolBox.

The campaign passed all 14 runtime, 16 PostgreSQL store and 25 durable recovery
cases, plus ten workload probes and eleven rejected unsafe configurations.
Additional worker OOM, database-outage and deadline cases preserved execution
identity and unknown outcomes without replay, retaining capacity until owned
absence was verified. The physical host also terminated a frozen outer VM,
rebuilt its disposable disk and verified a clean replacement execution.

If the outer guest kernel stops responding, recovery uses the physical host's
45-minute QEMU deadline plus stop grace, rather than the worker's 300-second
clock. The tests do not cover arbitrary images, concurrent tenants, external
networking or macOS host limits. Guest symlinks can still reach other paths
inside the guest; canonical workspace containment remains unsupported.

The full
[Linux qualification guide](https://github.com/hfiguera/smolbox/blob/v0.1.1/docs/linux-production-qualification.md)
describes the deployment, reproduction steps and limitations. The bundled
[Linux candidate evidence](evidence/linux-production-qualification.json)
records source identities, kernel counters, successful checks and retained failed
attempts. Its scripts target that disposable lab; installing the Hex package or
following Getting Started does not configure this deployment.

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
all conditions. No disk-fill or process-exhaustion experiment was run in that
initial increment. The next section records the earlier shared-storage failure;
the [subsequent campaign](#subsequent-linux-deployment-validation) adds measured
host OOM, task denial, CPU throttling and recovery with separate storage.

The probe also observed one guest CPU/affinity, no host test sentinel in its
environment, no rollout token, and no host qualification workspace path. These
checks do not establish that every control-plane route or credential is isolated.
Both probe VMs were stopped/deleted only after comparing their full recorded
creation evidence, and subsequent inspection observed absence. The owned Linux
unit was stopped after verifying its invocation ID and empty inventory. No
unrelated service or VM was stopped.

## Contained Linux exhaustion and slow-reader experiments

Two later experiments used fresh owned worker data directories mounted as
512 MiB tmpfs filesystems inside private user/mount namespaces. The same
unprivileged account launched user-systemd units with independently verified
kernel limits: 2 GiB memory, no swap, 200% CPU quota and 128 host tasks. Units had
a 300-second deadline and control-group teardown; the launcher imposed a
270-second deadline and 512 KiB worker-log cap. The normal worker and shared host
mounts were untouched. A prior 1 MiB mount preflight actually reached `ENOSPC`.
These are exploratory development-host experiments, not a supported provisioner
or production profile.

The released runtime and approved Python artifact stayed outside the writable
data mount. Inside the namespace, `SMOLVM_VM_UID_DROP=off` and
`SMOLVM_DISABLE_SHARED_EXTRACT=1` were required test settings. Both boots logged
a failed systemd scope-adoption attempt lasting ten seconds. The VMM remained in
the verified capped parent unit; per-VM scope adoption and service-restart
independence were not established. Creation took about 254 ms and start about
10.036 seconds, dominated by that timeout. Fresh data roots do not make those
numbers a default deployment or cold-host benchmark.

The first guest observed one vCPU and consumed about 3.997 CPU seconds in a
four-second loop. Thirty-two finite `sleep` children all completed. The parent
unit peaked at 26 host tasks and did not hit its task limit. This directly
illustrates why a host task cap does not count guest processes; a hard guest
process-count control remains unsupported. The CPU trial did not cause observed
parent-quota throttling and is not evidence of a CPU-time quota.

A finite disk producer attempted at most 640 MiB in 1 MiB writes with `fsync`
after every write. At 336,592,896 guest bytes it received `EIO`. The private host
mount was exactly full at 536,870,912 bytes. The parent unit's recorded memory
peak was 866,095,104 bytes, with no cgroup OOM/max event. The guest could still be
stopped, but the subsequent delete returned an uncertain protocol error.
SmolVM's own log reported that committing VM removal failed because its database
or disk was full. Read-only inventory confirmed the same owned machine remained
stopped. Source orders database removal before data-directory removal.

This is a cleanup failure that operators must account for. Guest writable data
can exhaust space needed by the worker's control metadata. Capacity reservations
alone do not prevent it. A production storage design needs verified control-plane
headroom or separately bounded storage, plus ownership-aware recovery when the
API cannot commit cleanup. Do not mark deletion complete or release reservations
on the basis of a stop response. The experiment ended by verifying and stopping
only its exact owned unit; its processes/cgroup disappeared and its private
in-memory mount was destroyed. This teardown is **not** a successful API delete.

The subsequent nested Linux deployment used separate 768 MiB VM/cache and 64 MiB
control-metadata mounts. Its disk-full trial retained metadata headroom and
completed stop, API deletion and absence verification. That result addresses
the failure for the tested storage layout; it does not repair or erase the
earlier shared-storage result. See
[Subsequent Linux deployment validation](#subsequent-linux-deployment-validation).

A [September 10 retest of SmolVM 1.14.6](#shared-storage-cleanup-retest)
reproduced the original shared storage failure on 1.14.1 and verified the upstream
deletion fix on 1.14.6. The historical measurements above remain unchanged.

The second guest attempted at most 64 MiB of output while its client's stream
callback blocked. SmolBox retained a 64 KiB capture limit and ended observation
after 3,003 ms; the callback process was gone and the VM still running. The
reported outcome stayed unknown with no exit code. Actual emitted bytes were
not recovered, so the upper bound must not be described as a completed 64 MiB
transfer. Explicit ownership-checked stop/delete then succeeded, inventory was
empty, and the owned unit exited. Its memory peak was 324,579,328 bytes and
sampled tmpfs use peaked at 194,314,240 bytes; no cgroup OOM or task-limit event
occurred. One finite producer does not prove safety against arbitrary hostile
protocol frames or all server-buffering patterns.

[Contained Linux evidence](evidence/phase8-linux-containment.json) retains
settings, kernel counters, raw-report/source hashes, successful checks and failed
cleanup. The normal worker remained healthy with empty inventory after both
trials. Equivalent independently bounded macOS experiments and broader isolation
qualification are unverified and outside the first release.

## Shared storage cleanup retest

On September 10, 2026, a targeted comparison ran inside the disposable nested
Linux lab on `ssh linux`. It used SmolBox 0.1.1's unchanged production library,
Elixir 1.20.4 / OTP 29.0.6, the approved Python image, and the complete official
SmolVM 1.14.1 and 1.14.6 distributions. Their source and binary hashes, individual
reports, and fixture corrections are recorded in
[the cleanup evidence](evidence/smolvm-1.14.6-cleanup.json).

Both versions placed their registry and VM data on the **same 512 MiB tmpfs**.
Device IDs verified that the paths shared a filesystem. A dedicated worker had
a 2 GiB cgroup memory maximum, zero swap, 200% CPU bandwidth, 128 host tasks and
a 300-second deadline. The outer QEMU retained the existing lab controls.
The workload attempted at most 640 MiB in 1 MiB writes with `fsync` after every
write. No host producer filled any remaining space.

| Observation | SmolVM 1.14.1 | SmolVM 1.14.6 |
|---|---|---|
| Shared filesystem after guest writes | All 536,870,912 bytes consumed | All 536,870,912 bytes consumed, in all three completed trials |
| Guest result | `EIO` after 330,301,440 written bytes | `EIO` after 329,252,864 to 330,301,440 written bytes |
| Stop | Succeeded; released one 4 KiB block | Succeeded; released one 4 KiB block |
| API delete | Uncertain protocol error; worker logged `commit vm removal: database or disk is full` | Succeeded in all three trials |
| Storage after delete | Still full; same owned VM remained stopped in inventory | Only 188,416 bytes (184 KiB) used; VM data directory absent |
| Worker restart and subsequent work | Not counted as successful cleanup; owned service teardown required | Deleted VM remained absent; a new VM passed create/start/upload/exec/download/stop/delete/absence |

This reproduces the original failure mechanism in a nested environment. It does
not reproduce every detail of the earlier direct-host user-namespace experiment:
the kernel, account setup, private Unix endpoint and Elixir/OTP pair differ.
Guest acknowledged bytes also vary with filesystem overhead. Both comparison
versions used the same lab layout and guest workload.

[Upstream PR #1219](https://github.com/smol-machines/smolvm/pull/1219), included in
[SmolVM 1.14.6](https://github.com/smol-machines/smolvm/releases/tag/v1.14.6), moves
VM data removal before the registry write in the HTTP API deletion path. Removing
that data frees space for the metadata transaction in this shared filesystem
case. Our observation confirms the released behavior through `SmolBox.Client`;
it does not attribute every difference between the two complete distributions
to that one patch.

The result does not cover a separately full metadata filesystem, a read-only or
failing filesystem, permission errors during removal, forked machines, or
concurrent tenants. It does not replace control storage headroom and recovery
design. **SmolBox's supported runtime pin remains 1.14.1**: this finite client
regression check is not the full compatibility, managed recovery, or release
qualification suite for 1.14.6. No macOS validation ran.

The [lab guide](https://github.com/hfiguera/smolbox/blob/main/docs/nested-kvm-lab.md#retesting-shared-storage-cleanup)
describes how to run the maintained reproduction. Private raw reports remain on
the Linux host; repository evidence contains reviewed observations and hashes.

## Finite macOS guest-memory overload

A separate macOS arm64 experiment created a neutral 256 MiB, one-vCPU Python
machine on the normal development worker. A child attempted at most 384 MiB in
1 MiB allocations, with a 15-second child deadline. The child exited with
signal 9; the guest kernel `oom_kill` counter advanced from zero to one and its
log identified an OOM-killed Python process. The parent command exited zero and
the VM remained running. Guest `MemTotal` was 244,820 KiB after kernel overhead.
Explicit ownership-checked stop/delete then succeeded and inventory was empty.

The first trial's assertion incorrectly tried to match the command-local child
PID directly against the guest-kernel log PID. It failed and is retained as a
failed fixture. The second trial records both domains (child PID 3; kernel log
PID 188), the kernel counter and bounded OOM log evidence without asserting an
unverified mapping. Both trials' owned machines were cleaned up. See
[macOS guest-memory evidence](evidence/phase8-macos-memory.json).

This completes a finite guest-allocation/overload observation on each platform.
It does not provide independent macOS host RSS, CPU-time, disk or process limits,
nor qualify arbitrary hostile protocols. Those production-profile guarantees
remain unsupported.

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
does not turn the first measured submission into a cold-host experiment. The later private-worker trial below separates an empty Linux image cache from
subsequent cache reuse. No pristine/cold OS-host result is claimed.

## Empty image cache versus cached extraction

A later Linux trial used a new private `SMOLVM_DATA_DIR` on an already-running
host, with the default shared-extraction path enabled. Before its first
submission, the data root contained only the new worker database files and no
shared extraction cache. The pinned distribution and Python artifact were
already present; host page caches and the normal worker were untouched. The
same durable benchmark ran twenty sequential submissions and its normal queue,
slow-consumer, preparation-failure and uncertain-cancellation phases.

| Measurement | First cache-miss sample (n=1) | Cached samples 2–20 (n=19) |
|---|---:|---:|
| Outcome, seconds | 2.171 | median 1.956; p95 2.184 |
| Through cleanup, seconds | 2.477 | median 2.220; p95 3.413 |
| Create request, milliseconds | 218.895 | median 17.263; maximum 20.055 |

There is only one cache-miss sample; no cold-cache percentile or reliable
speedup estimate follows from it. Cached cleanup had two larger observations,
so the p95 remains 3.413 seconds rather than dropping them. This separately
started worker also differs from the earlier normal worker; end-to-end changes
cannot be attributed solely to cache state. Polling, PostgreSQL, staging,
execution, collection and cleanup remain included in the reported path.

After the trial, its private shared extraction tree contained 797 entries with
130,871,296 allocated regular-file bytes and 21,602,145,645 logical bytes,
including sparse image data. Cache storage is additional host accounting;
initial allocated blocks are not a future disk-usage bound. All 28 accepted
executions released reservations, all notification checks passed, and inventory
was empty. The exact owned worker unit was then stopped after verifying its
PID, cgroup and invocation identity. Private settings, keys, database and cache
remain as evidence. An omitted object directory initially failed host setup
before submission; that attempt is retained and no accepted command was replayed.

Pinned source makes shared pack extraction Linux-only. On macOS, each packed
machine creation clears/rebuilds its own extraction directory and owns its own
case-sensitive volume. The previously recorded twenty macOS samples therefore
include per-machine extraction on an already-running host; a Linux-style shared
extraction cache-hit path is unavailable. Source evidence explains the platform
path without inventing a macOS cached-extraction result.

[Cache-state evidence](evidence/phase8-cache-state.json) records every sequential
sample, the initial/final cache state, matching benchmark source hashes,
resources and report identities. These measurements distinguish image-cache
availability from OS-host startup. Network image acquisition, pristine-host boot
and statistically broad cold-cache distributions remain unmeasured and are not
part of the reported performance claim.

## Evidence needed for stronger future claims

The subsequent Linux campaign provides the enforcement and recovery evidence
summarized above. New evidence is needed before extending those results to
different deployment assumptions, runtime versions, kernels or images.
Concurrent tenants, external networking, arbitrary images, independent macOS
host limits and broader protocol or credential-access behavior remain outside
the measured scope. The finite probes do not establish the absence of every
kernel, hypervisor or runtime vulnerability.

Protected real-worker GitHub infrastructure was not provisioned as part of these
local campaigns. Recorded local runs remain distinct from CI execution.
Pristine-host and broader cold-cache performance claims also need separate
trials. Preserve the historical measurements and their conditions when comparing
them with later deployments.
