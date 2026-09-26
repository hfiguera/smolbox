# Checkpoint examples and measurements

These scripts default to smolvm 1.19.0 in this checkout. Set
`SMOLBOX_RUNTIME_VERSION=1.16.1` for an existing 1.16.1 worker and matching
checkpoint capture. Published SmolBox 0.1.5 supports 1.16.1 only. Read
[checkpoint approvals](../../docs/checkpoints.md) before restoring a fixture.
Use a dedicated idle worker, private artifact paths and synthetic data. Do not
use arbitrary application checkpoints or a shared production worker.

## Fixtures

`prepare-fixture.sh SOCKET NEW_CHECKPOINT_PATH` creates a bare offline source,
starts it as branchable, writes disk/RAM markers and captures it. Creation and
execution replies are saved beside the checkpoint. The source remains alive
for inspection; the script does not silently delete it after a failed request.

To prepare the dataset benchmark while that source is still running:

```sh
bash scripts/checkpoints/prepare-dataset.sh \
  /private/worker/api.sock \
  /private/bare.smolcheckpoint.create.json \
  /private/dataset.smolcheckpoint
```

This generates one million deterministic synthetic readings for 1,000 stations,
compresses the source CSV on disk, aggregates counts and sums into
`/dev/shm/stations.tsv`, and saves a serialized copy on disk. All preparation
commands finish before capture. The checkpoint contains idle guest state, not a
running query server. No Python interpreter or imported modules are preserved.

After inspecting the saved replies, stop the source and export a `.smolmachine`
pack including its workspace using smolvm's operator CLI. Use the same runtime,
data root and configuration as its server. The pack and checkpoint must originate
from that same source. The image boots afresh and loses `/dev/shm`; the checkpoint
restores it. Verify the source's saved creation identity before deleting it and
require an empty inventory before benchmarking. Do not retry a potentially
accepted capture/start/stop operation simply because a response was lost.

## Timing a pair of approved artifacts

Run on the worker host with the pinned Elixir toolchain:

```sh
SMOLBOX_CHECKPOINT_SOCKET=/private/worker/api.sock \
SMOLBOX_CHECKPOINT_PATH=/approved/dataset.smolcheckpoint \
SMOLBOX_COLD_PATH=/approved/dataset.smolmachine \
SMOLBOX_BENCH_WORKLOAD=dataset \
SMOLBOX_BENCH_SAMPLES=10 \
SMOLBOX_CHECKPOINT_CACHE_MODE=enabled \
mix run scripts/checkpoints/benchmark.exs > results.json 2> creation-evidence.jsonl
```

There are three workloads:

- `bare`: read the disk marker, with no application preparation.
- `dataset`: the image decompresses and aggregates the CSV into RAM before the
  query; the checkpoint already contains that table.
- `dataset-precomputed`: the image copies the serialized table into RAM instead
  of recomputing it. This is a stronger baseline for data that can be serialized.

Both sources must return the same query result. Each run measures create, start,
application preparation, query and deletion separately. Time to result is the
sum of the first four stages per sample. It excludes the later identity inspection
and cleanup. Creation includes SmolBox's checkpoint version preflight. These are
low-level `Client` measurements, not PostgreSQL-backed managed runtime latency.

One warmup per source is excluded, then source order alternates. The default is
10 measured samples per source, bounded to 1–50. Setup, capture, packing, artifact
transfer and image downloads are outside the timed path for both sources. The
script checks creation identity before disposal, observes absence, and requires
an empty final inventory. Failed runs retain their last creation observations
in stderr; inspect them rather than blindly rerunning the script.

## Comparing Linux cache settings

`SMOLBOX_CHECKPOINT_CACHE_MODE` only labels the report. It does **not** configure
the worker. On smolvm 1.16.1 Linux workers, setting
`SMOLVM_DISABLE_SHARED_EXTRACT=1` disables shared extraction; leaving that variable
**unset** enables it. Setting it to `0` still disables it. Change the worker
configuration only between runs with no machines remaining, then verify actual
shared extraction in server evidence rather than trusting the label.

Keep runtime, artifacts, privileges, limits, filesystem and logging the same.
Run disabled, enabled, enabled, disabled blocks, reversing workload order in the
second pair. Preserve warmup samples, outliers and raw timings. Enable smolvm's
info logs to collect its `api_restore_*` phase timings and join them by machine
name. Logging is part of the measured configuration.

An ordinary user worker can use shared extraction directly. A privileged worker
with per-VM UID isolation uses an idmapped mount; its startup costs and resource
placement differ. Do not combine their timing samples. Run privileged experiments
only inside the disposable Linux lab, and verify all machines and scopes are gone
before shutting it down. Do not infer macOS cache behavior from these Linux tests.

The small synthetic table is deliberately serializable. Saving it in an image
may be a better choice than a checkpoint. These measurements do not establish a
universal speedup, tail-latency target, workload isolation guarantee or the
performance of live branching or `checkpoint://` prepared references.
