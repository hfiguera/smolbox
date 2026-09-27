# Exports, checkpoints and branches on physical Linux

This September 27, 2026 campaign compares the time to a correct result through
SmolBox's managed APIs and PostgreSQL store. It covers a fresh local artifact,
a prepared registry export, a checkpoint, a live branch and an existing machine.
It is a small workload on one physical Linux host, not a general performance
ranking or a release qualification for every application.

## What each path buys

| Path | Starting state | Meaning of reuse |
| --- | --- | --- |
| Fresh local artifact | Empty project in a local bare pack | A new machine repeats dataset preparation |
| Export | Stopped source published to a local registry | A new boot with prepared disk files; RAM starts afresh |
| Checkpoint | Approved capture of an idle prepared bare guest | A new machine restores disk and RAM |
| Branch | Running, idle prepared bare source on this worker | A new child inherits disk and RAM; source backing remains relevant |
| Existing machine | The prepared source remains running | Another command in the same environment; no new isolation |

The workload generates one million deterministic readings for 1,000 stations,
compresses the CSV, aggregates it into `/dev/shm/stations.tsv`, and saves a
serialized table on disk. Every trial must return `42 1000 5054000` for station 42.
There is no live query server, imported Python environment or running application
captured in these measurements.

Exports load the saved table into RAM rather than recomputing the aggregate.
That is an important baseline: a checkpoint should not get credit for avoiding
work that an ordinary disk artifact can avoid too.

## Results

| Path | Disk result median | RAM result median | RAM result p95 | Cleanup median |
| --- | ---: | ---: | ---: | ---: |
| Fresh local artifact | 4.364 s | 4.652 s | 4.752 s | 0.131 s |
| Prepared export | 0.741 s | 1.191 s | 1.533 s | 0.141 s |
| Checkpoint restore | 0.677 s | 0.897 s | 1.049 s | 0.133 s |
| Live branch | 0.621 s | 0.853 s | 1.024 s | 0.166 s |
| Existing machine | 0.194 s | 0.447 s | 0.558 s | 0.000 s |

“Disk result” includes managed creation and start where applicable, preparation
for the fresh path, and one verified disk query. “RAM result” is cumulative from
the same start through a second verified RAM query, including the instrumentation
gap between stages. Export also copies the saved table into RAM and verifies that
it was not already present. Query submission, durable writes and controller
polling are included. This is not raw hypervisor boot time.

Each path has 20 measured trials and one excluded warmup. Order rotates each
round. p95 is the nineteenth sorted observation out of twenty; these sample counts
do not establish a production tail-latency target. All observations, including
warmups and outliers, are retained in the evidence.

## Preparation and lifecycle costs

| Stage | Observed time |
| --- | ---: |
| Create and start checkpoint source | 0.574 s |
| Prepare checkpoint source data | 3.645 s |
| Capture, verify and resolve checkpoint | 0.494 s |
| Delete checkpoint source | 0.132 s |
| Create and start export source | 0.487 s |
| Prepare export source data | 3.592 s |
| Stop export source | 0.389 s |
| Publish and resolve export | 8.637 s |
| Delete export source | 0.142 s |

Parent setup: median **4.412 s** across five batches. Parent deletion and backing release: median **0.340 s**.

Preparation rows are single observations, not distributions. Initial fixture
construction and provisioning the registry/PostgreSQL services are outside them.
Export publication uses a loopback registry and includes packing and upload;
it does not measure a remote network or a private registry authentication service.

A prepared branch/reuse parent remains alive during every path. Its setup and
final deletion are separate rows. The harness starts another parent after five
branch trials because SmolBox retains the full extra branch allowance until the
source is deleted and backing removal is verified. Five parent batches cover the
21 trials per path, including warmup. Their setup cost must be included when
planning a short batch; the readiness table assumes that preparation already exists.

Individual branch cleanup deletes the child and retires its dependency. It does
**not** release the extra backing allowance. Parent deletion, backing checks and
allowance release are timed separately. Existing-machine cleanup is a no-op until
that parent is deleted. The benchmark uses ordinary immediately running branches;
held branchpoints and explicit release latency are outside this comparison.

## Resources

| Path | Worker CPU through RAM result, median | Worker baseline, median | Worker peak, median | Allocated file block increase, median |
| --- | ---: | ---: | ---: | ---: |
| Fresh local artifact | 3799 ms | 1094 MiB | 1191 MiB | 1.33 MiB |
| Prepared export | 264 ms | 1093 MiB | 1181 MiB | 0.71 MiB |
| Checkpoint restore | 179 ms | 1093 MiB | 1225 MiB | 6.89 MiB |
| Live branch | 265 ms | 1093 MiB | 1157 MiB | 0.96 MiB |
| Existing machine | 44 ms | 1094 MiB | 1095 MiB | 0.00 MiB |

The single export preparation peaked at **3.74 GiB** of worker cgroup memory. Its sampled worker-data peak was **2.89 GiB**, from **0.82 GiB** before publication. These temporary costs are easy to miss if only restore latency is compared.

These are whole-worker measurements, including the live parent, caches and
retained generations. They are not per-VM RSS, isolation guarantees or deployment
sizing recommendations. The worker cgroup excludes PostgreSQL, the controller
and registry. Kernel `memory.peak` is reset on an open file descriptor for each
stage, with baseline memory recorded alongside it. Cache charges can persist
between modes; compare the raw baseline as well as the peak. The final cgroup
reported 5,808 `memory.high` events across its descendants and no OOM kill; these
measurements include the worker's memory pressure controls, not unlimited memory.

Disk values use allocated file blocks, not exclusive physical extents. They can
count shared extents more than once. Peak disk sampling every 250 ms can miss
shorter peaks. Temporary files can disappear during a scan; those observations
are counted explicitly as approximate in `worker_disk_scan_races`. Other scan
errors abort the run. Resource counters cover a slightly wider interval than the
wall timer because their reads and disk sampling surround the timed operation.

## Conditions and limits

- SmolBox main commit `6c925c6d8a43eec555c959b91602c8d366be1e17`, smolvm 1.19.0,
  Elixir 1.20.4, OTP 29.0.6, PostgreSQL 16.15; controller `+S 4:4`.
- Physical Intel Core i5-1135G7, four cores/eight threads, 64 GiB RAM, Pop!_OS,
  Linux `7.1.5-76070105-generic`, ext4 storage, CPU governor `powersave`.
  `systemd-detect-virt` reported `none`; live VM/VCPU KVM descriptors were observed.
- An ordinary user worker, 4 CPU quota, 8 GiB cgroup memory maximum, no swap,
  256 tasks; each guest requests 1 CPU, 256 MiB RAM, 1 GiB storage and 1 GiB overlay.
- Dedicated worker/data root, local registry and database. Other existing host
  services were left running. This was not a CPU-pinned, otherwise idle machine.
- Disk/shared extraction caches remained from pilot runs. The worker was restarted
  during recovery before the completed campaign. No caches were dropped. Even the
  first retained warmup is **not** a pristine-host or fully cold-cache result.
- Fresh/export use a local pack and its registry export. Checkpoint/branch use an
  approved native bare seed. They run the same synthetic workload and allocations,
  but the source representations differ. SmolBox rejects captured packed-layer
  dependencies, so a common packed source would not be a supported comparison.
- Checkpoints preserve CPU/runtime-specific guest state. This campaign does not
  establish portability to another CPU, OS, runtime version or worker.
- No nested virtualization, macOS series, remote registry, OCI image pull,
  concurrent workload, large working set or automatic replay was tested here.

## Failures and cleanup evidence

All 100 measured trials and five warmups passed their disk/RAM checks. All 84 new
machines (21 each for fresh, export, checkpoint and branch) passed the source
unchanged check after child writes. Five parents were explicitly deleted. No
worker OOM kill was observed. Three transient missing-file observations were
counted by the repaired disk sampler.

An earlier campaign stopped at fresh sample 3 because the original sampler
assumed `du` would never race a temporary-file removal. Its incomplete rows are
retained and excluded. Recovery fenced old worker requests by restarting the owned
service, checked recorded ownership, removed remaining machines, resolved absence
and released backing/capture accounting. A subsequent launch was rejected before
creation because that recovery had not yet finished. The completed campaign uses
a fresh durable partition; no failed command was replayed.

Setup pilots also exposed the packed-layer capture restriction and several harness
issues, recorded individually in `attempts.json`. They are not included in the
statistics. Final completed-campaign inventory was empty. Retained capture storage
was explicitly removed and its allowance released: slots, CPUs, memory and disk
reservations were all zero for every pilot and campaign. The dedicated worker and
registry services were then stopped. Artifact caches and the published registry artifact
remain separate host storage, not a claim of zero disk usage.

The completed run is kept separate from setup pilots and the interrupted run.
Correct result checks, child writes that leave source disk/RAM unchanged, verified
machine absence, and explicit capacity release are acceptance criteria alongside
latency. This finite workload check does not prove general application isolation
or replace the feature qualification suites.

## What to use these numbers for

Avoiding repeat preparation is the large difference in this workload. An export
already reduces median time through the RAM query from 4.65 s to 1.19 s with a
simple serialized table. Checkpoint and branch medians are close, at 0.90 s and
0.85 s; their observed ranges overlap, so this campaign does not justify a broad
claim that one is faster.

Choose an export when saved disk files are sufficient and a new boot is useful.
Choose a checkpoint when preserving approved RAM state matters and its runtime/CPU
constraints are acceptable. Choose branches for children of a prepared live source
when you can retain and manage its backing dependencies. Reuse the existing machine
when you want continuity and do not need a fresh environment. Account for preparation,
retention and cleanup as well as the readiness number.

## Reproduce and inspect

The [benchmark harness](https://github.com/hfiguera/smolbox/tree/main/scripts/benchmarks/provisioning)
contains physical-host prerequisites, fixture construction, managed phases,
metric definitions, recovery guidance and summary tests. Its fixture builder was
also run successfully on a second dedicated physical Linux worker. CI checks the
parser/summary tests and reproduces the committed summary from the raw rows; CI
does not rerun physical-worker timings. The
[raw evidence](https://github.com/hfiguera/smolbox/tree/main/docs/evidence/provisioning-2026-09-27)
contains all completed rows, the interrupted rows, attempt history, artifact and
harness hashes, host evidence, summaries and cleanup receipts. No credentials,
private database records or VM artifacts are published.
