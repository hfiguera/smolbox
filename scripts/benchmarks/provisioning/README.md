# Managed provisioning on physical Linux

Compare useful results from five supported paths, not just a successful start:

| Path | Work inside the measured readiness interval |
| --- | --- |
| `fresh` | Create/start a local bare pack, generate and aggregate the dataset, query disk |
| `export` | Create/start the prepared registry artifact, query disk; then load the serialized table into RAM |
| `checkpoint` | Create/start an approved prepared checkpoint, query its restored disk and RAM |
| `branch` | Create an ordinary, immediately running child of an idle prepared source, query disk and RAM |
| `reuse` | Query the existing prepared source; no new isolated machine |

Preparation, capture, stop, export publication, source setup, isolation checks and
cleanup have separate rows. Checkpoints and branches preserve an idle RAM table,
not a running application. Exports get the stronger serialized-table baseline;
they do not unnecessarily repeat an aggregation that can be saved on disk.

## Prerequisites

Use a dedicated **physical Linux** host with KVM. The harness refuses a host when
`systemd-detect-virt` identifies virtualization. This probe is one piece of evidence;
also inspect the host deployment and live KVM file descriptors. Do not run this
against a shared worker. Linux access in the development environment is available
through `ssh linux`; no nested VM or macOS series belongs in these results.

Use smolvm 1.19.0, the repository's Elixir/OTP versions, Python 3, GNU `du`, cgroup
v2 with writable per-file-descriptor `memory.peak` reset, PostgreSQL and a local OCI
registry with **enforced create-only tags**, anonymous reads and a publisher bearer
token. The registry must reject overwrites; `immutable_tags: true` is an operator
assertion, not registry enforcement. Follow the [export setup](../../../docs/machine-exports.md)
and [durable host example](../../../examples/durable_host/README.md).

Reserve a new private root (`mktemp -d`, mode 0700), a new database and unused ports.
Create `worker`, `config`, `cache`, `scratch`, `artifacts`, `captures`, and `results`
under it. Create separate random 32-byte `encryption.key` and `fingerprint.key`
files, mode 0600, and save the registry publisher token to `publisher.token`.
Never include those files or a database dump in published evidence.

Start the worker as a dedicated systemd user service with these limits:

```text
CPUQuota=400%
MemoryMax=8G
MemorySwapMax=0
TasksMax=256
RuntimeMaxSec=7200
KillMode=control-group
```

Its environment must point `SMOLVM_DATA_DIR` to `ROOT/worker`, `XDG_CONFIG_HOME`
to `ROOT/config`, `XDG_CACHE_HOME` to `ROOT/cache`, and `TMPDIR` to `ROOT/scratch`.
Set `SMOLVM_GUEST_ROLLOUT_HOST_PORT` to a separate unused port and `RUST_LOG=warn`.
Run `smolvm serve start -l 127.0.0.1:WORKER_PORT`. Keep the registry, PostgreSQL
and controller outside the worker cgroup. Use the actual service `ControlGroup`
path, including its supervisor and VM descendants, for resource measurements.
Leave shared extraction enabled; do not drop host caches during a campaign.

Save an absolute-path JSON configuration:

```json
{
  "root": "/private/new-benchmark",
  "partition": "campaign1",
  "samples": 20,
  "worker_url": "http://127.0.0.1:54897",
  "registry": "127.0.0.1:48123",
  "smolvm": "/approved/smolvm-1.19.0/smolvm",
  "base_path": "/private/new-benchmark/bare-base.smolmachine",
  "seed_path": "/private/new-benchmark/seed.smolcheckpoint",
  "worker_data": "/private/new-benchmark/worker",
  "cgroup": "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/benchmark.service"
}
```

The ports and cgroup path above are examples. Select your own free ports and the
correct UID/service. Run `python3 scripts/benchmarks/provisioning/fixture.py CONFIG`
on the Linux worker host. It requires an empty inventory, creates a synthetic
bare guest, captures its idle state, stops it, creates a pack, verifies ownership,
and deletes it. A failure retains creation evidence for operator recovery.
Inspect and approve both artifacts before continuing. The seed is needed because
SmolBox rejects managed capture of packed-layer checkpoint dependencies; a local
pack and a bare checkpoint are distinct source representations.

## Run

Configure `SMOLBOX_DATABASE_SOCKET_DIR`, `SMOLBOX_DATABASE_PORT`,
`SMOLBOX_DATABASE_USER`, and `SMOLBOX_DATABASE_NAME` for the **new** database, or
use `DATABASE_URL`. From `examples/durable_host`, with `MIX_ENV=test` and
`ERL_FLAGS='+S 4:4'`:

```sh
mix deps.get
mix ecto.migrate
mix run ../../scripts/benchmarks/provisioning/run.exs /absolute/config.json prepare
mix run ../../scripts/benchmarks/provisioning/run.exs /absolute/config.json measure
mix run ../../scripts/benchmarks/provisioning/run.exs /absolute/config.json cleanup
```

Each phase creates an exclusive `PHASE.started` marker before dispatch and a
`PHASE.completed` marker only on success. Do not remove a marker and retry after
failure. Inspect intent, durable state and the worker, fence old requests when
necessary, and use the documented recovery APIs. Use a fresh partition and
capture directory for a new campaign **after** cleaning up the prior machines.
The harness never automatically replays unknown work.

The final cleanup removes this campaign's captured checkpoint only after all
machines are gone, verifies its original digest, and releases retained capture
accounting. Branch allowances are released only after source and children are
deleted and their machine directories and scratch staging are absent. `_shared`
and `_cow-bases` are artifact caches, not VM directories. They and the registry
artifact remain host-owned storage outside machine reservations. Stop only your
owned services after saving evidence; retain the private database and keys for
recovery or explicitly dispose of that dedicated lab later.

Summarize only a complete run:

```sh
python3 scripts/benchmarks/provisioning/summarize.py \
  ROOT/results/campaign1/rows.jsonl --samples 20 > summary.json
```

Also require all three `.completed` markers, empty final worker inventory and
`final-usage.json` with every reservation at zero. Save hardware/runtime/toolchain
versions, source and harness hashes, cgroup limits, cache conditions, live KVM
evidence, raw rows and failed attempts with your report. The summary rejects
missing/duplicate stages, explicit failures, OOM kills and invalid warmup labels.

## Interpretation

One warmup per path is retained and excluded. Twenty measured samples use rotating
path order; empirical p95 is the nineteenth sorted observation, not a production
latency guarantee. Parent setup/cleanup is repeated every five branch samples to
respect the conservative retained backing allowance. Its cost is separate and
must not be described as free. A prepared parent stays alive during every mode.

`ready` includes managed create/start, PostgreSQL writes, controller polling and
one correct disk query. `memory-ready` is the subsequent RAM query (plus export
loading). The summary's cumulative RAM latency includes the instrumentation gap
between these stages. Each invocation has its own monotonic clock origin; never
subtract timestamps across `prepare`, `measure` or `cleanup` processes.

Worker CPU and memory cover the whole worker cgroup, including the parent, caches
and retained generations. Memory is a per-stage kernel peak, not RSS or a per-VM
allocation. It excludes controller, registry and PostgreSQL memory. GNU `du`
reports allocated file blocks, not exclusive physical extents; sampled peaks at
250 ms can miss brief peaks. Vanished temporary paths are counted in
`worker_disk_scan_races`; those observations are approximate. Other scan failures
abort rather than fabricate a measurement. CPU counters include measurement
setup/teardown outside the reported wall-clock interval.

The small synthetic table deliberately favors serialization. Do not generalize
results to servers, large working sets, OCI pulls, remote registries, held branch
release, concurrent tenants, pristine host caches or different CPUs. Reuse provides
no new isolated environment. The branch isolation check covers synthetic disk/RAM
writes, not a general security claim.

Local harness checks:

```sh
elixir scripts/benchmarks/provisioning/metrics_test.exs
python3 -m unittest discover -s scripts/benchmarks/provisioning -p 'test_*.py'
```
