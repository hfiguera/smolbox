# Direct and nested KVM performance comparison

Measured September 16, 2026 (September 17 UTC), entirely on the authorized
`ssh linux` host. Branch: `benchmark-nested-kvm`. SmolBox library code and the
published packages are unchanged.

**The largest difference was startup.** In these six pairs, a new microVM reached
its first successful command in a median 1.43 seconds directly on Linux and
8.04 seconds in the nested lab. A short CPU calculation inside an already running
guest had overlapping timings. File processing and the complete managed job
were slower in the nested configuration.

This is a comparison of two concrete deployments on one machine. The results
do not isolate a universal cost attributable solely to nested virtualization.

## Results

Each cell shows **median (minimum–maximum)** across six measured samples.
One completed warmup per configuration is retained separately and excluded.
Ratios divide the nested median by the direct median. The evidence also includes
ratios within each alternating pair; these are different statistics.

| Measurement | Direct Linux | Nested Linux | Ratio of medians |
|---|---:|---:|---:|
| Create, start, first successful command | 1.431 s (1.379–1.798) | 8.045 s (7.532–8.941) | 5.62× |
| `/bin/true` on a running VM, client round trip | 95.6 ms (56.5–105.7) | 91.2 ms (59.7–106.0) | 0.95× |
| CPU calculation, measured inside guest | 311.4 ms (286.6–353.0) | 308.9 ms (283.5–336.9) | 0.99× |
| CPU command, client round trip | 479.3 ms (442.5–525.2) | 567.9 ms (544.8–585.7) | 1.18× |
| File write, fsync, read and hash inside guest | 179.3 ms (161.6–498.1) | 441.7 ms (426.0–463.5) | 2.46× |
| Managed file job through output collection | 2.409 s (2.109–2.477) | 8.899 s (8.456–9.314) | 3.69× |
| Managed file job through verified cleanup | 3.136 s (2.329–3.236) | 9.319 s (8.845–10.724) | 2.97× |

The CPU and tiny-command ranges overlap. The ratios slightly below one are not
evidence that nesting improves performance. The direct file measurements include
a 498 ms sample; it is retained. Six observations do not establish reliable tail
latency or a narrow confidence interval.

The client measurement includes request handling, process startup and response
delivery. The Python timer starts inside the program, after interpreter startup.
The distinction matters: an unchanged calculation can still have a slower
client-visible completion time.

The file workload writes **36 MiB**, flushes and calls `fsync`, reads it back,
checks its SHA-256, and removes it. The CPU workload sums two million integer
squares with a fixed integer mask. All CPU results and both low-level and managed
file hashes match the expected values in every measured sample.

## Configuration and method

- Physical host: Intel Core i5-1135G7, four cores/eight threads, approximately
  64 GiB RAM, Pop!_OS, Linux `7.1.5-76070105-generic`.
- Nested worker host: the existing disposable Ubuntu lab, Linux
  `6.8.0-139-generic`, four vCPUs, 8 GiB RAM and a 100 GiB virtual disk.
- Both configurations: official smolvm **1.16.0**, published SmolBox **0.1.3**,
  Elixir **1.20.4**, OTP **29.0.6**, identical locked dependencies, and the same
  approved Python artifact. Runtime, agent, libkrun and libkrunfw hashes match.
- Each microVM: one vCPU, 512 MiB RAM, requested 1 GiB storage/1 GiB overlay,
  offline networking, neutral `/bin/true` entrypoint. Both worker hosts have
  the resizing prerequisite. The inner guest uses Linux **6.12.95** and
  Python **3.12.14** in both configurations.
- Each private worker service: 200% CPU quota, 4 GiB charged memory, no swap,
  192 tasks, 30-minute lifetime, whole-cgroup teardown. The outer lab retains
  its four-CPU bandwidth, 12 GiB host memory and 45-minute service deadline.
- Controllers run beside their worker with two BEAM schedulers and communicate
  through private Unix sockets. SSH starts each controller but is outside its
  measured intervals. The managed runtime uses the same ephemeral memory store
  and directory artifact adapter in both configurations.

Preparation downloads, dependency compilation, artifact preparation and template
decompression occur before measurement. Host caches are warm; no host cache
dropping or frequency changes were performed. Each sample creates a fresh VM for
the low-level measurements and another fresh VM for the managed job. The outer
lab stays running while direct samples execute, with no nested job running.

Pair order alternates: direct then nested for odd pairs, nested then direct for
even pairs. Only one job runs at a time. The managed interval starts immediately
before `SmolBox.submit/2`, records completed output collection, then waits for
`cleanup: :complete`, released capacity and an empty dedicated worker inventory.
It excludes controller boot and initial source seeding, and includes guest source
staging, execution and report collection. Cleanup is polled at 10 ms intervals.

All twelve measured samples passed without retries or exclusions. Both warmups
passed. CPU counters show **zero throttled periods** in either worker and zero
outer-VM throttling during the measured intervals. Worker memory counters show
no limit events or OOM kills. Both workers peaked below 450 MiB of charged memory.

There was no adversarial workload or resource exhaustion test. Direct host inputs
were trusted finite programs with 60-second command limits, an eight-minute
sample timeout, and checks for test storage growth and remaining host capacity.
The existing host worker and unrelated workloads were left running.

## What these numbers do and do not answer

They answer the reader's question for our lab: **nesting added substantial startup
cost, while this short CPU calculation did not show a comparable slowdown**.
The complete SmolBox job reflects that startup cost as well as its file processing,
collection and cleanup.

The worker kernels differ. Direct storage is host ext4; nested storage goes
through guest ext4 and a QEMU qcow2 overlay on the lab's ext4 backing volume.
Filesystem options and caches also differ. The file test uses buffered writes
and guest `fsync`; it is not a direct-I/O or cold-storage throughput measurement,
nor does it establish persistence after physical power loss.

CPU affinity was not pinned, Turbo remained enabled, and the host's existing
`powersave` governor was unchanged. Other host services remained present. This
small campaign does not characterize concurrent tenants, large working sets,
network traffic, every CPU family, or a production workload. No causal breakdown
of the slower startup was measured. The old article used smolvm 1.14.1; these
new measurements use 1.16.0 and do not retrospectively benchmark that campaign.

SmolBox does not require nested virtualization. Nesting was chosen for disposable
failure tests; a worker can run directly on a suitable Linux host.

## Evidence and reproduction

[Machine-readable evidence](evidence/nested-kvm-performance.json) contains all
twelve samples, both warmups, medians/ranges, paired ratios, cgroup counter
deltas, input identities and cleanup results. The benchmark script's exact
SHA-256 is `a04caa337a35989a4df9d88bab061037c178f45cf1b493c2445a2226e8e2f5fb`.
The private raw archive has SHA-256
`a64fa2e74180d5873c73c61224ebcfb9ba2713995e3a26be1a5507b899b38a7c` and remains
on Linux under `/var/lib/smolbox-lab/staging/benchmark-20260916/`, with a local
ignored copy under `.local/nested-benchmark/`.

The scripts in [scripts/benchmarks](../scripts/benchmarks/) are maintainer tools
for this approved Linux lab, not a general worker installer:

1. Start a clean disposable guest using the [lab procedure](nested-kvm-lab.md).
   Create separate private worker directories on the physical host and guest.
   Install identical verified runtime archives, predecompress the disk templates,
   and copy the approved Python artifact as `python.smolmachine` in each directory.
2. Prepare an identical `consumer/` Mix application with published SmolBox 0.1.3
   and its locked dependencies. Compile outside timed intervals. Use the same
   Elixir/OTP pair and `ERL_FLAGS='+S 2:2'` in both environments.
3. Prepare private `home`, `data`, `cache`, `tmp` and `docker` directories and an
   empty `empty-config.toml`. Copy `worker.sh`, `capture-kvm.sh` and
   `nested-kvm.exs` into each worker directory. Start `worker.sh ROOT` in the
   bounded `smolbox-benchmark.service` user unit with the limits above. Save its
   full `/sys/fs/cgroup/...` path in `ROOT/worker-cgroup`.
4. Verify empty inventories and effective limits. The direct host requires a
   separate bounded traced pilot recording successful `KVM_CREATE_VM` and
   `KVM_CREATE_VCPU` calls in `ROOT/kvm-proof.txt`. Stop tracing before timing.
   Nested samples use privileged, read-only inspection of owned VM/vCPU
   descriptors. Guest user lingering must keep its service alive between SSH
   sessions. No physical-host administrative changes are required.
5. From each `consumer/`, run `mix run ../nested-kvm.exs ROOT LABEL warmup`, using
   `MIX_ENV=prod` and `LABEL` of `direct` or `nested`. Then run
   `bash scripts/benchmarks/run-pairs.sh DIRECT_ROOT NESTED_ROOT GUEST_SSH_HELPER`
   on the physical host. The helper is the existing host-side `guest-ssh.sh`.
   The reusable runner parameterizes the paths used by the recorded campaign;
   the exact executed controller script is retained in the raw archive.
6. Export all sample reports and outer-counter snapshots to one directory, add
   the deployment's reviewed `metadata.json`, and run
   `mix run summarize.exs REPORT_DIRECTORY OUTPUT_JSON` in the consumer. The
   summarizer requires all six pairs, successful statuses, expected computation
   results and file hashes, and matching input identities.
7. Export evidence before teardown. Verify both inventories are empty, stop the
   two owned worker services, and confirm their cgroups disappear. Stop the outer
   lab through `labctl.sh`, then observe recovery complete. Do not reuse sample
   identities after an uncertain command or overwrite failed reports.

Direct `/proc` descriptor access was restricted by runtime process hardening.
Five initial diagnostic low-level runs ended at instrumentation assertions and
are excluded from timing; their owned machines were deleted. The successful
traced pilot explicitly observed KVM creation. A noexec staging mount, stale
user-manager group access, guest service lifetime and trace filtering were also
corrected during preparation. These are harness setup corrections, not omitted
measured failures. The measured runs were all untraced.

Final inventories were empty; both worker cgroups disappeared after shutdown.
The outer VM stopped and its recovery marker cleared. The original physical-host
smolvm worker remained running. All benchmark execution, summary validation,
Elixir formatting and ShellCheck checks ran through `ssh linux`.
The expected CPU sum and file digest were independently recomputed in Elixir.
The summary validator also rejected a deliberately incorrect computation result
and a missing measured sample, without producing a passing summary.
