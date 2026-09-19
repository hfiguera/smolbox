The report asks about one station. Before it can answer, the job decompresses a
million readings and builds a summary table. The next report asks about another
station, then repeats the same preparation.

Each job needs its own disposable environment. Does it also need to rebuild the
same data?

[SmolBox 0.1.5][hex] adds execution from approved idle, offline checkpoints. You
can prepare guest state once, capture it with smolvm, and restore a separate VM
for each execution. That includes data in RAM that would disappear during a
normal boot.

There is a useful catch: sometimes saving the prepared data in an image is
enough. We tested that too.

## What is worth keeping?

In our [previous performance experiment][previous], starting a fresh microVM
cost much more in the nested Linux lab than on the physical host. That raised a
second question: which work actually needs to happen again?

A prepared image already keeps installed tools and files. If your expensive step
is downloading dependencies, putting them in the image may solve the problem.
A checkpoint also captures memory and processes. It can keep a prepared table
in `/dev/shm`, a filesystem backed by RAM, ready for the next command to read.

For SmolBox's first checkpoint contract, **preparation must finish before
capture**. The source is an approved idle guest, with networking off and no
pending user work, credentials or connections. SmolBox does not expose capture
or live branching through its managed API. The operator prepares and approves
the source with smolvm 1.16.1, then registers it with the application.

That boundary matters. Restoring memory also restores any captured processes;
declaring a checkpoint idle does not make a busy application stop.

## One million readings, one small answer

Our fixture generates a million synthetic readings across 1,000 stations. It
compresses the source CSV on disk, then aggregates counts and sums into
`/dev/shm/stations.tsv`. All preparation commands exit before capture. There is
no query server left running.

A query for station 42 is just:

```sh
awk '$1 == 42 {print}' /dev/shm/stations.tsv
```

It returns `42 1000 5054000`: the station ID, its reading count and their sum.
This is deliberately a small, inspectable workload. Elixir could answer this
query directly; the point is to compare ways of preparing a disposable guest,
using the same data and result.

We compared three ways of reaching that answer:

| Approach | What happens before the query |
| --- | --- |
| Image with the source CSV | Boot, decompress the readings and rebuild the table in RAM. |
| Image with a precomputed table | Boot and copy the saved table into RAM. |
| Checkpoint with the table in RAM | Restore the idle guest, with the table already present. |

The second row is important. A checkpoint should be compared with a sensible
prepared image, not only with an application that repeats avoidable work.

## Submit work against the approved state

SmolBox still manages an execution: its identity, command, collected output and
cleanup. The source changes from an image to a checkpoint.

Before this excerpt, the operator has approved a Linux checkpoint, verified its
digest and captured resource profile, and protected its path on the worker.
The application registers it in the worker's checkpoint catalog. The
[checkpoint guide][guide] covers that configuration and the equivalent setup
for macOS Apple Silicon; each platform needs its own prepared source.

With `checkpoint` and its matching `profile` registered in `MyApp.Sandboxes`:

```elixir
{:ok, command} =
  SmolBox.Command.new([
    "/bin/sh",
    "-c",
    "awk '$1 == 42 {print}' /dev/shm/stations.tsv"
  ])

{:ok, spec} =
  SmolBox.ExecutionSpec.new(
    scope: "station-reports",
    id: "station-42-report-001",
    artifact: SmolBox.Checkpoint.artifact(checkpoint),
    profile: profile,
    command: command
  )

{:ok, handle} = SmolBox.submit(MyApp.Sandboxes, spec)
{:ok, execution} = SmolBox.await(MyApp.Sandboxes, handle, 90_000)
```

This is the submission portion, not a standalone application. Check the observed
outcome and exit code before using `execution.result.stdout`, and wait for
cleanup separately. The [runnable examples][examples] include configuration,
submission and the wait for verified disposal; the dataset preparation and
comparison scripts reproduce the workload above.

Each new execution gets its own restored machine. Changes made by one job must
not become the next job's starting state. Reusing an execution ID still means
the same execution, not a request for another VM. A lost command response still
does not authorize replay.

## What the measurements showed

Before looking at the station workload in the nested lab, the
[native measurements][native] help put the gains in perspective.

Reading a small marker took a median of 598 ms from creation through the result
with an image and 497 ms with a checkpoint on macOS. On Linux, those medians were
457 ms and 407 ms.

Those were five samples per source with warm host caches. The Linux worker had
shared extraction disabled. They show that avoiding a fresh boot can help, but
restoring a checkpoint has costs of its own.

The station experiment was a separate campaign in our **disposable nested Linux
lab**, using smolvm 1.16.1 with shared extraction enabled and an ordinary user
worker. Each microVM had one vCPU and 256 MiB RAM. The outer guest had four vCPUs
and 8 GiB RAM on an Intel Core i5-1135G7 host with 64 GiB RAM.

These medians cover creation through the query result:

<table class="benchmark-results">
  <thead><tr><th scope="col">Starting point</th><th scope="col">Time to result</th></tr></thead>
  <tbody>
    <tr><th scope="row">Image, rebuild the table</th><td>6,678 ms</td></tr>
    <tr><th scope="row">Image, load the precomputed table</th><td>5,388 ms</td></tr>
    <tr><th scope="row">Checkpoint, table already in RAM</th><td>597 ms</td></tr>
  </tbody>
</table>

Each displayed median uses ten measured samples after warmup. Source order
alternated, and the broader experiment repeated cache configurations in reverse
order. Artifact preparation, capture, downloads and later cleanup are outside
these timings. These are measurements through SmolBox's low level client, not
complete managed jobs with PostgreSQL persistence and output collection.

**Fresh image boot was unusually slow in this nested setup.** The large gap is
not a speedup to expect on native Linux or macOS. The useful observation is that
both precomputing the table and preserving it in RAM removed repeated work.

Worker configuration mattered too. For a small marker command in the same lab,
enabling shared extraction reduced checkpoint time to result from 751 ms to
614 ms, about 18%. The [protocol][protocol] explains the setting, and the
[recorded samples][evidence] include the separate phases and configurations.

## A checkpoint is not an interpreter pool

Our fixture preserves data in RAM. It does not preserve a Python interpreter
waiting for requests. Starting `python report.py` after restoration creates a
new process, which still needs to import its modules.

If the cost you want to avoid is interpreter initialization, this example does
not establish that checkpoints remove it. Keeping a running application ready
to accept new work would require a different lifecycle contract from the idle
sources SmolBox supports today.

For this small table, saving it in the image is also a reasonable choice. It
keeps preparation explicit and avoids managing a memory capture. A checkpoint
becomes worth investigating when prepared guest state is useful to preserve
and the restore cost is justified by your actual workload.

Checkpoint files contain memory. Treat them as sensitive artifacts, keep them
under operator control, and validate them on the intended worker. This feature
does not add a new isolation guarantee.

## Reuse preparation, keep executions separate

The useful change is a choice of starting state. Each execution can begin with
the same approved preparation while keeping its own identity, result and
verified cleanup.

Start by identifying what your job repeats. If an image can carry that work
forward, use it. If prepared memory is the missing piece, measure a checkpoint
against that image on your own worker.

For existing applications, read the [0.1.5 upgrade procedure][upgrade] before
submitting checkpoint work: every controller sharing the store must support the
new checkpoint records.

[hex]: https://hex.pm/packages/smolbox/0.1.5
[previous]: ../measuring-nested-kvm-overhead/
[guide]: https://hexdocs.pm/smolbox/0.1.5/checkpoints.html
[examples]: https://github.com/hfiguera/smolbox/tree/v0.1.5/scripts/checkpoints
[protocol]: https://github.com/hfiguera/smolbox/tree/v0.1.5/scripts/checkpoints#comparing-linux-cache-settings
[evidence]: https://hexdocs.pm/smolbox/0.1.5/evidence/checkpoint-cache-benchmark.json
[native]: https://hexdocs.pm/smolbox/0.1.5/evidence/checkpoint-executions.json
[upgrade]: https://hexdocs.pm/smolbox/0.1.5/recovery.html#upgrading-to-0-1-5
