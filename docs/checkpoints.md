# Executing from a checkpoint

This unreleased feature restores a separate disposable machine from an
operator-approved **idle, offline checkpoint**. Submission, input staging,
command execution, output collection, cancellation and cleanup use the existing
managed lifecycle. Each execution gets its own identity and machine.

Use a checkpoint when keeping prepared guest state is useful. For example, a
reference dataset in `/dev/shm` survives restoration even though a normal boot
would lose it. Disk changes made by one execution must not change the checkpoint
or a later execution.

A checkpoint also contains running processes. It is **not** just another image
format. This first contract excludes captured user workloads, background tasks,
credentials and network connections. It does not expose live branching, capture,
pools or arbitrary resume through the managed API. A newly executed Python
process does not inherit another process's imported modules. Do not expect this
API to make interpreter initialization disappear.

## Prepare and approve the source

Use a dedicated preparation worker running smolvm **1.16.1** on the same platform
and compatible CPU as the execution worker. Prepare a bare, offline guest with
no host mounts, ports, sockets, devices, secret references or workload restart.
Wait for all preparation commands to exit. Capture the idle guest using smolvm's
checkpoint operation. This preparation is outside SmolBox's managed API.

The repository's `scripts/checkpoints/prepare-fixture.sh` creates a small example
with a file in `/workspace` and another in `/dev/shm`. It requires a dedicated
worker Unix socket and a new absolute `.smolcheckpoint` output path. It saves
source creation evidence beside the checkpoint; inspect the responses and delete
the source only after verifying that evidence. On failure, retain the evidence
for investigation. This fixture uses only the guest's shell, not Python.

Before registering a checkpoint:

- Verify its SHA-256 and protect its worker path against replacement.
- Inspect its captured state: no pending user work, credentials or connections.
- Verify the exact CPU, memory and disk allocations and that networking is off.
- Exercise restoration, execution and cleanup on the intended worker platform.

The worker's artifact checksum check establishes internal integrity, not that it
matches your approved SHA-256. As with image approvals, SmolBox cannot remotely
attest the worker's file contents. Operator-controlled immutable paths and host
access control are required. Checkpoint files contain memory and must be treated
as sensitive artifacts, not public downloads.

Run the complete example from the checkout after approving the fixture:

```sh
SMOLBOX_CHECKPOINT_SOCKET=/private/worker/api.sock \
SMOLBOX_CHECKPOINT_PATH=/approved/idle.smolcheckpoint \
mix run scripts/checkpoints/run.exs
```

This example runs on the worker host so it can hash the local file. Remote
controllers use the digest verified by their operator instead. The demo uses
an ephemeral store, prints both restored markers, and waits for cleanup.

For PostgreSQL persistence, independent restores and recovery in a fresh
application process, use the
[durable checkpoint example](https://github.com/hfiguera/smolbox/tree/main/examples/durable_host#checkpoint-execution-and-recovery).
It includes a focused controller interruption suite. Both examples require this
unreleased checkout; the published 0.1.4 package does not include this feature.

## Register a checkpoint

```elixir
{:ok, profile} =
  SmolBox.Profile.new("idle-shell-v1",
    cpus: 1,
    memory_mb: 256,
    storage_gb: 1,
    overlay_gb: 1,
    host_overhead_mb: 256,
    preparation_ms: 60_000
  )

{:ok, checkpoint} =
  SmolBox.Checkpoint.new(
    id: "idle-shell-v1",
    sha256: verified_sha256,
    architecture: "x86_64",
    platform: :linux,
    path: "/approved/idle.smolcheckpoint",
    profile: profile
  )
```

Use `platform: :macos, architecture: "aarch64"` for an independently prepared
Apple Silicon checkpoint. Registration is a declaration of approval, not a file
inspection. The default `resume: :idle` describes the only accepted contract; it
does not stop captured processes.

Pass `checkpoints: [checkpoint]` to `SmolBox.Runtime.WorkerConfig.new/1`, along
with its usual client, platform, architecture, profiles, capacity and allocation
floor. Use `artifacts: []` for a checkpoint-only worker, or retain approved image
entries. The checkpoint's full profile must appear in the worker's profile
catalog. Its runtime, platform and architecture must match that worker. Keep
allocation floors consistent with actual captured disks and runtime overhead.

Checkpoint execution currently requires 1.16.1. Existing image execution retains
its other explicitly supported runtime versions and controlled networking.

## Submit a command

With that worker in the supervised runtime:

```elixir
{:ok, command} =
  SmolBox.Command.new(["/bin/sh", "-c", "cat /dev/shm/smolbox-marker"])

{:ok, spec} =
  SmolBox.ExecutionSpec.new(
    scope: "reports",
    id: "report-001",
    artifact: SmolBox.Checkpoint.artifact(checkpoint),
    profile: profile,
    command: command
  )

{:ok, handle} = SmolBox.submit(MyApp.Sandboxes, spec)
{:ok, execution} = SmolBox.await(MyApp.Sandboxes, handle, 90_000)
```

The reference includes the source kind, ID, digest and architecture. It cannot
alias an image with the same ID. Duplicate submissions still return the same
handle. Changing the source or profile under an existing execution ID conflicts.
Handle errors and unknown outcomes, and inspect cleanup separately from command
completion as described in [Recovery](recovery.md).

## What restoration verifies

SmolBox uses `POST /api/v1/machines` with the approved worker checkpoint path.
It does not upload checkpoint bytes or introduce a shell/CLI transport.
Creation installs the checkpoint without starting the guest. SmolBox requires a
created, branchable machine with the expected allocations and offline network
policy before saving creation evidence and starting it.

The request omits disk resize and workload override fields: upstream rejects
changes to captured topology, and an entrypoint cannot replace resumed memory.
A mismatched or lost creation response does not authorize starting, retrying or
deleting the machine. Capacity remains reserved pending reconciliation or operator
resolution. Staging begins only after a verified start of the same incarnation.

Restored files are subject to the same bounded file API and symlink limitations
as ordinary image executions. Uncertain command outcomes retain the same no-replay
and preservation rules. A failed graceful stop never automatically authorizes
forced disposal.

## Persistence and upgrades

Checkpoint records use **record schema v3**. This implementation reads existing
v1/v2 image records and keeps writing image records as v2, preserving existing
image fingerprints. Only checkpoint executions require v3.

Upgrade every controller sharing a store before accepting checkpoint submissions.
Older controllers cannot read v3 records; they must never treat them as absent.
Once checkpoint records exist, rolling back to 0.1.4 requires separating or
migrating those records with an explicit operational plan. Changing only the
worker does not upgrade the controllers.

## Performance and validation

A checkpoint avoids a fresh guest boot but adds checkpoint verification and
restore work. Benefits depend on the captured state, artifact size, host caches
and workload. `scripts/checkpoints/benchmark.exs` measures create, start, exec
and delete separately against an equivalent cold VM pack. It uses five measured
samples per source after warmup, alternating order. It does not measure image
pulls or establish a universal speedup.

The [qualification record](evidence/checkpoint-executions.json) includes the raw
samples and native runtime checks. In the tiny bare-guest benchmark, median time
from creation through the command result was 598 ms for the image and 497 ms for
the checkpoint on macOS; on Linux it was 457 ms and 407 ms. Creation includes the
checkpoint client's version preflight. Startup improved, but checkpoint creation
cost more. These are five samples per source with warm host caches; application
initialization, larger captures and cold caches can change the result. Normal native
checks run on Linux x86_64 and macOS Apple Silicon; adversarial or exhaustion
work belongs only in the disposable Linux lab. Networked checkpoint execution,
cross-platform restoration and arbitrary resumed workloads are not supported.

The [durable example validation](evidence/checkpoint-durable-example.json) separately
covers PostgreSQL recovery across fresh BEAM processes in the disposable Linux
lab: completed records, independent restores, and interruption immediately before
and after the result commit. Those three cases verify no command replay, retained
identity, the appropriate known or unknown outcome, and cleanup with capacity
release. They do not constitute the full image recovery campaign or a macOS
durable checkpoint qualification.

Run the dedicated real checkpoint suite only after preparing and approving its
fixture. The existing `test/runtime` suite continues to cover supported image
workers without requiring a checkpoint:

```sh
SMOLBOX_CHECKPOINT_SOCKET=/private/worker/api.sock \
SMOLBOX_CHECKPOINT_PATH=/approved/idle.smolcheckpoint \
mix test test/checkpoint_runtime --include runtime --warnings-as-errors
```
