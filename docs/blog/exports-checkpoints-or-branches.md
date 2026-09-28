You have prepared a VM. The files are in place, a useful table is already in
memory, and the next task needs the same starting point.

Should you export the machine, save a checkpoint, or create a branch?

SmolBox 0.3.0 supports all three. They preserve different things, start the next
machine differently, and leave different cleanup obligations. Choosing well can
save repeated work. Choosing by the smallest timing number alone can give you a
lifecycle you did not want.

**Start with the state you need to keep. Then compare the cost of keeping it.**

We will use one prepared dataset, the measurements from our physical Linux
campaign, and a browser example you can run yourself. The measurements use
smolvm 1.19.0. They describe one small workload, not a universal performance ranking.

## What should survive into the next machine?

Suppose your preparation produces two things: a serialized table on disk and an
aggregate already loaded into RAM. Both can answer the same query. The question
is how much of that preparation the next machine needs to repeat.

<figure class="reuse-figure" id="reuse-lab" aria-labelledby="reuse-caption">
  <div class="reuse-controls" hidden>
    <div class="reuse-choices" role="group" aria-label="Reuse approach">
      <button type="button" data-reuse-mode="export" aria-pressed="true">Export</button>
      <button type="button" data-reuse-mode="checkpoint" aria-pressed="false">Checkpoint</button>
      <button type="button" data-reuse-mode="branch" aria-pressed="false">Branch</button>
    </div>
    <div class="reuse-playback">
      <button type="button" class="reuse-play">Play path</button>
      <button type="button" class="reuse-next">Next step</button>
      <span class="reuse-progress" role="status" aria-live="polite" aria-atomic="true">Step 1 of 4. Prepared state.</span>
    </div>
  </div>
  <div class="reuse-stage" data-mode="export" data-step="0">
    <p class="reuse-headline">Keep the files. Start with a new boot.</p>
    <p class="reuse-detail">An export keeps supported disk contents. The next guest loads its table into RAM again.</p>
    <div class="reuse-route">
      <div class="reuse-node reuse-source">
        <strong>Prepared original</strong>
        <span class="reuse-source-status">Preparation finished</span>
        <div class="reuse-state"><span>Disk</span><b class="reuse-source-disk">Saved table</b></div>
        <div class="reuse-state reuse-memory"><span>RAM</span><b class="reuse-source-ram">Table loaded</b></div>
      </div>
      <div class="reuse-bridge">
        <svg viewBox="0 0 160 52" aria-hidden="true"><path class="reuse-track" d="M0 16H154l-8-6m8 6-8 6M0 38H154l-8-6m8 6-8 6"/><path class="reuse-transfer" d="M0 16H154"/><path class="reuse-transfer reuse-ram-transfer" d="M0 38H154"/></svg>
        <strong class="reuse-carrier">Registry artifact</strong>
        <span class="reuse-carried">Disk, without RAM</span>
      </div>
      <div class="reuse-node reuse-target">
        <strong class="reuse-target-name">Next machine</strong>
        <span class="reuse-target-status">A fresh boot</span>
        <div class="reuse-state"><span>Disk</span><b class="reuse-target-disk">Saved table</b></div>
        <div class="reuse-state reuse-memory"><span>RAM</span><b class="reuse-target-ram">Load from disk</b></div>
      </div>
    </div>
    <div class="reuse-retained"><strong>What remains</strong><p class="reuse-retention">Deleting the source does not remove the published registry artifact.</p></div>
  </div>
  <figcaption id="reuse-caption">An explanatory model, not a live VM or a timing animation. Choose a path and step through preparation, reuse and cleanup. The checkpoint and branch cases assume an approved idle, offline bare guest. An export requires a stopped source.</figcaption>
</figure>

### Export when the files are enough

An export publishes supported disk state from a **stopped machine** to an
approved registry destination. The next machine boots from that artifact.
It does not resume the old processes or recover their memory.

For our table, that is already useful. The next guest reads the serialized
result from disk instead of rebuilding it from a million input rows. Prepared
tools, configuration and generated files are other reasons to choose an export,
provided they live in paths the exporter actually preserves.

That last detail matters. On smolvm 1.19.0, a container export through the HTTP API
**excludes `/workspace`**, host mounts and temporary filesystems. Container root
filesystem changes are supported; bare VM exports preserve the storage and
overlay disks used by the pack exporter. Check the [export guide][exports] before
assuming that a file inside the guest will appear in the artifact.

### Checkpoint when approved memory state matters

A checkpoint saves **disk and RAM**. An explicit restore creates an independent
managed machine from that saved state. In this example, the prepared table is
already in memory when the restored guest runs its query.

That is useful when a saved memory state avoids meaningful work that loading a
normal disk artifact would still require. It also comes with stronger constraints:
CPU, platform and runtime compatibility matter. Our measurements do not establish
portability to another worker or CPU.

SmolBox 0.3.0 manages capture from approved **idle, offline bare guests** on
smolvm 1.19.0, without ports or startup workloads. It does not turn an arbitrary
running service into a safely resumable application. The host must establish that
the state is safe to capture; an empty command slot does not prove that no
background process is running.

Restore is explicit creation, not an undo button on the existing machine. A later
normal stop/start preserves disks but does not restore the captured RAM again.
The [checkpoint guide][checkpoints] explains the approvals and recovery contract.

### Branch when you want another machine from a live source

A branch creates a new child from an approved **running but idle source on the same
worker**, including its disk and RAM state. The child gets its own managed identity.
Changes to its guest files or memory do not change the source or sibling guests.

This fits a set of experiments that need the same prepared starting point. A
branch copies the running source directly; it does **not** first save a checkpoint
and restore that file.

The tradeoff is the relationship you keep. Branch backing remains relevant after
the child starts. Source stop/start/delete stays blocked until child dependencies
are retired, and deleting a child alone does not release the extra backing
allowance. This first contract supports leaf branches from idle, offline bare
guests, not arbitrary application cloning or migration. See the
[branch guide][branches] for the complete lifecycle.

| Approach | Next machine | Source relationship |
| --- | --- | --- |
| Export | Fresh boot with supported disk contents. RAM starts fresh. | Independent of the source after publication. |
| Checkpoint | Independent restore of captured disk and RAM. | Independent of the source after capture. |
| Branch | Independent child with copied disk and RAM. | Source dependency remains until retirement; backing remains until verified cleanup. |

## One workload, five starting points

Our campaign generated one million deterministic readings for 1,000 stations,
compressed the CSV, aggregated it into `/dev/shm/stations.tsv`, and saved a
serialized table on disk. Every trial had to return the same verified station
result: `42 1000 5054000`.

We compared the three reuse approaches with two useful baselines:

- **Fresh machine:** start from a local bare artifact and repeat dataset preparation.
- **Existing machine:** run another command in the same prepared environment.

The export path loaded the saved table into RAM. It did not recompute the
aggregate. A checkpoint should not get credit for avoiding work that a disk
artifact can avoid too.

There was no application server, imported Python environment or large model
captured in this workload. It was a small data preparation and query experiment.

## What the measurements actually say

The chart measures time from the managed request through a **verified RAM query**.
It includes creation and start where needed, the earlier disk query, durable store
writes, controller polling and the instrumentation gap between stages. It is not
raw VM boot time. Preparation of the reusable artifact or live parent is outside
these per-trial values.

<figure class="reuse-benchmark">
  <picture>
    <source media="(max-width: 600px)" srcset="../../media/exports-checkpoints-or-branches/results-mobile.svg" />
    <img src="../../media/exports-checkpoints-or-branches/results.svg" width="960" height="490" loading="lazy" alt="Median seconds through a verified RAM query: fresh 4.652, export 1.191, checkpoint 0.897, branch 0.853, existing machine 0.447. Dots mark p95: 4.752, 1.533, 1.049, 1.024 and 0.558 seconds respectively." />
  </picture>
  <figcaption>20 measured trials per path, plus one excluded warmup. Physical Linux, smolvm 1.19.0, warm caches and a local registry. Bars show medians; dots show p95. The full report includes every sample and the host configuration.</figcaption>
</figure>

**Avoiding repeated preparation was the large difference.** The export reduced
median time through the RAM query from 4.65 seconds to 1.19 seconds. We already
kept most of the useful work simply by saving a table to disk.

Checkpoint restore and branching were closer: 0.90 and 0.85 seconds. Their observed
ranges overlap. This campaign does not justify a general claim that branches
are faster than checkpoints.

The existing machine was quickest here, at 0.45 seconds. If you need continuity
and do not need a separate environment, another command on that machine may be
the right answer. It also means keeping its accumulated state.

These numbers come from one physical Intel host, with guest allocations of one
CPU and 256 MiB RAM, a PostgreSQL store and existing caches. The worker operated
under CPU and memory controls and recorded memory pressure events. Fresh/export
and checkpoint/branch paths used different supported source representations,
while keeping the workload and allocations the same. We did not test nested
virtualization, remote registry latency, concurrent jobs or a large working set.

Read the [method, raw evidence and limits][measurements] before using these values
for planning. With 20 samples, p95 is the nineteenth sorted observation; it is
not a production tail latency promise.

## Preparation has a bill, too

The fast path starts after someone has done the preparation.

In this campaign, preparing the source data took about 3.6 seconds. Export
publication then took **8.637 seconds**, including packing and upload to a local
registry. Checkpoint capture, verification and resolution took **0.494 seconds**.
Those preparation rows are single observations, not distributions, and exclude
initial fixture construction and registry/database provisioning.

A branch also needs its live parent. Parent setup had a median of **4.412 seconds**
across five batches. For a short batch, that cost can outweigh a small difference
in per-child readiness. The harness replaced its parent after five branch trials
because retained backing allowances continued to count until source cleanup.

Storage and memory matter too. The export preparation observed a worker memory
peak of **3.74 GiB**, despite the query guest requesting only 256 MiB. A small
guest allocation does not describe the resources needed to produce its artifact.

For your workload, compare the complete run: prepare once, serve however many
tasks you expect, keep the required state, and clean it up. Measure the useful
result you need, rather than treating one startup number as the whole cost.

## Deleting a machine is only part of cleanup

The three paths leave different objects behind:

| Path | What needs its own lifetime |
| --- | --- |
| Export | The published registry artifact, any copies and host caches. Deleting the source does not remove them. |
| Checkpoint | The saved file and partial or extra copies. Artifact disk accounting remains until removal and explicit release. |
| Branch | Child machines, source dependencies and retained backing. Child deletion and dependency retirement precede source deletion; backing release follows verified host cleanup. |

SmolBox records intent, identity and uncertainty around these operations. It does
not infer that a lost response means nothing happened, or replay unknown work
under a new ID. Its resource reservations are accounting decisions, not physical
filesystem or memory quotas.

In the completed campaign, all 100 measured trials and five warmups returned the
expected results. Child writes left source disk/RAM checks unchanged. Final
cleanup verified machine absence and released all SmolBox reservations. Published
artifacts and shared caches still had their own host storage lifetime. “Zero
reservations” did not mean “zero bytes left on the host.”

## Try the difference yourself

The [community workspace example][workspace] now has a separate **Saved state**
walkthrough. It uses the published SmolBox 0.3.0 package and keeps the everyday
workspace separate from the offline bare guest used for this experiment.

On a dedicated Linux worker with smolvm 1.19.0, PostgreSQL, an approved Python
artifact for the everyday workspace and an approved idle bare checkpoint seed:

1. Follow the pinned README's setup, resource approvals and seed verification.
2. Create and prepare the saved state workspace. It writes a file on disk and a note in RAM.
3. Save a checkpoint and complete the explicit capture confirmation.
4. Create a branch of the running original and change the branch's recipe.
5. Read both guests. The original keeps “basil and lemon”; the branch says “ginger and lime.”
6. Restart the controller with the same database and private configuration, then inspect the same identities and results.
7. Use the separate cleanup actions and verify host files before releasing their reservations.

That browser flow has [real physical Linux evidence][workspace-evidence]. It
demonstrates capture, live branching, disk/RAM isolation and recovery of the
management records. It does not restore the downloaded capture or demonstrate
registry export. For those paths, use the released durable host's
[export example][export-example] and [capture/restore example][checkpoint-example].

## Where SmolBox 0.3.0 fits

This release adds managed registry and OCI sources, stopped machine exports,
checkpoint capture with independent restore, and live branches. SmolBox supplies
the Elixir API, durable ownership, lifecycle coordination and conservative recovery
around smolvm's underlying machinery.

Existing local artifact workflows remain available. Before enabling the new
record types, [upgrade every shared controller, reader and store adapter][upgrade].
The PostgreSQL example needs no additional SQL migration for 0.3.0, but that does
not make older readers compatible with the new records. Worker installation and
version selection remain separate from updating the Elixir dependency.

For a prepared filesystem and a fresh boot, start with an export. For approved
memory state you need to restore later, consider a checkpoint. For separate tasks
from a live prepared source, consider branches and plan for their backing lifetime.

**What does your next task actually need to inherit: files, memory, or the same
ongoing environment?** That answer is more useful than a speed ranking.

[exports]: https://hexdocs.pm/smolbox/0.3.0/machine-exports.html
[checkpoints]: https://hexdocs.pm/smolbox/0.3.0/managed-checkpoints.html
[branches]: https://hexdocs.pm/smolbox/0.3.0/managed-branches.html
[measurements]: https://github.com/hfiguera/smolbox/blob/v0.3.0/docs/provisioning-performance.md
[workspace]: https://github.com/hfiguera/smolbox/tree/7cb98bfb62ccf9e72cd3dd82bd5d8c7177374bc0/examples/community_workspace#saved-state-prepare-checkpoint-branch-compare
[workspace-evidence]: https://github.com/hfiguera/smolbox/blob/7cb98bfb62ccf9e72cd3dd82bd5d8c7177374bc0/examples/community_workspace/docs/saved-state-validation.md
[export-example]: https://github.com/hfiguera/smolbox/tree/v0.3.0/examples/durable_host#export-a-stopped-machine-and-reuse-its-artifact
[checkpoint-example]: https://github.com/hfiguera/smolbox/tree/v0.3.0/examples/durable_host#managed-checkpoint-capture-and-restore
[upgrade]: https://github.com/hfiguera/smolbox/blob/v0.3.0/docs/upgrading-to-0.3.0.md
