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

## Remaining evidence

Required work includes bounded CPU/process/disk/output stress under independently
verified host quotas, macOS resource qualification, server-side buffering and
slow-observer measurements, hostile path/credential/control-plane tests, and
repeatable release-worker jobs. Passing the ordinary execution and recovery
suites does not substitute for those experiments. The implementation plan keeps
minimal-profile certification unchecked.
