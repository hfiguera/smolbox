The project is fine. The machine is the part you want to replace.

Maybe you need a different toolchain. Maybe an experiment left the environment
hard to trust. You want a clean machine without uploading the same project again
or losing the files you just created.

A persistent machine helps until you delete it. **A managed volume lets the data
have a longer life than the machine.**

This walkthrough writes one file, deletes its machine, restarts the Elixir
controller, and reads that file from a replacement. Then it changes the file,
checks a read-only mount, and removes everything explicitly. One small file makes
the boundary easy to see before you put a real project behind it.

Local volumes arrived in SmolBox 0.4.0. The example below uses **SmolBox 0.4.1,
smolvm 1.22.0 and a Linux worker**, with PostgreSQL holding the management records.

## Give the project its own lifetime

A machine has its own identity, processes and disks. A managed local volume has a
separate identity and a directory on the worker. At creation, you attach the volume
at an approved guest path. The guest reads and writes that directory through the mount.

Deleting the machine ends the attachment. It does not delete the volume.
A replacement on the **same worker** can then mount the same data.

**The volume survives machine replacement; it still depends on that worker’s storage.**

<figure class="volume-figure" id="volume-lifecycle" aria-labelledby="volume-caption">
  <div class="volume-controls" hidden>
    <button type="button" class="volume-play">Play walkthrough</button>
    <button type="button" class="volume-next">Next step</button>
    <span class="volume-progress" role="status" aria-live="polite" aria-atomic="true">Step 1 of 6. Write the file.</span>
  </div>
  <div class="volume-scene" data-step="0">
    <p class="volume-headline">The first machine writes the file.</p>
    <div class="volume-machine">
      <svg viewBox="0 0 44 40" aria-hidden="true"><rect x="2" y="2" width="40" height="29" rx="2"/><path d="M14 38h16M22 31v7M9 11l5 4-5 4m10 0h8"/></svg>
      <div><strong class="volume-machine-name">Original machine</strong><span class="volume-machine-state">Running · can read and write</span></div>
    </div>
    <div class="volume-connection"><span class="volume-mount-label">Mounted at /mnt/volumes/data</span><svg viewBox="0 0 40 44" aria-hidden="true"><path d="M20 0v38m-6-6 6 6 6-6"/></svg></div>
    <div class="volume-data">
      <div class="volume-data-heading"><strong>Project volume</strong><span class="volume-reservation">2 GiB reserved</span></div>
      <div class="volume-file"><span>kept.txt</span><code class="volume-value">original</code></div>
      <p class="volume-retention">Its own identity. Kept until explicit deletion.</p>
    </div>
    <p class="volume-detail">The file lives on the volume. The machine’s other files and processes have their own lifetime.</p>
  </div>
  <figcaption id="volume-caption">Follow one volume through machine replacement and cleanup. This is an explanatory model, not a live worker or a timing measurement.</figcaption>
</figure>

Notice what stays in place: the volume. There is no export, copy, or restore
between these machines. The replacement reads the existing directory.

That also makes the boundary clear. A package installed elsewhere on the original
machine does not move with the project. Neither does a running development server
or a variable in memory. Prepare tools through the replacement’s approved image
and keep the data you want to reuse under the mount.

## Approve where the data lives

Use the [versioned durable host example][example] for the complete setup. It
includes the PostgreSQL adapter, migrations, worker configuration, command helpers
and cleanup checks. Start from the `v0.4.1` source in a separate checkout:

```sh
git clone --branch v0.4.1 --depth 1 https://github.com/hfiguera/smolbox.git smolbox-volume-demo
cd smolbox-volume-demo/examples/durable_host
```

Follow that README’s setup section before running the phases below. You need a
Linux worker running smolvm 1.22.0, an approved Python artifact, PostgreSQL and the
encryption and fingerprint key files. Keep the same worker, keys and store
partition between processes. Use a fresh execution ID and partition for this experiment.

The extra approval is the worker’s **actual canonical volume directory**:

```elixir
{:ok, policy} = SmolBox.VolumePolicy.new(
  "project-data",
  "/srv/smolvm/.local/share/smolvm/volumes"
)
```

That path is an example, not a universal default. Include the policy in the
worker’s `WorkerConfig`; the runnable demo builds it from `SMOLBOX_VOLUME_ROOT`.
SmolBox checks the worker’s returned path against this approved boundary. A mismatch
leaves an uncertain record with its reservation held, rather than allowing a mount.

Also verify permissions under your actual worker configuration. This walkthrough
uses an unprivileged worker with one host UID. It does not establish replacement
writes or tenant isolation for root-run workers that assign different UIDs to VMs.
The [volume guide][volumes] covers that boundary and host storage controls.

## Write once, then delete the original

These are the two API pieces the demo combines. First, create the volume and
confirm it is ready. A returned handle alone is not proof of successful provisioning.

```elixir
{:ok, volume} = SmolBox.Volumes.create(runtime,
  scope: "team-a", id: "project-data", worker_id: "linux-1", size_gb: 2)

{:ok, %{state: :ready}} = SmolBox.Volumes.inspect(runtime, volume)
```

Then refer to that volume when creating the machine. The application supplies an
approved artifact and resource profile; the caller does not supply a host source path.

```elixir
{:ok, mount} = SmolBox.VolumeMount.new("project-data", "/mnt/volumes/data")

{:ok, spec} = SmolBox.ManagedMachineSpec.new(
  scope: "team-a", id: "builder-one",
  artifact: approved_artifact, profile: approved_profile, volumes: [mount])

{:ok, machine} = SmolBox.Machines.create(runtime, spec)
```

These snippets explain the API. The complete demo handles waiting, starting,
command submission and observed deletion. After the README setup, run its first phase:

```sh
export SMOLBOX_EXECUTION_ID=volume-example
export SMOLBOX_STORE_PARTITION=volume-example
# Replace this with the directory your worker actually uses.
export SMOLBOX_VOLUME_ROOT=/srv/smolvm/.local/share/smolvm/volumes
mix ecto.migrate
mix run -e 'SmolBox.DurableHost.VolumeDemo.run("prepare")'
```

The original machine writes `original` to `/mnt/volumes/data/kept.txt`.
The demo checks that deleting an attached volume is blocked, then stops and
deletes the machine and verifies its absence.

At this point there are **no machines, but still 2 GiB of volume reservation**.
The directory and file remain on the worker. That is the result we want: deleting
compute has not silently discarded the project.

`size_gb` is an advisory reservation, **not a filesystem quota**. Host quotas and
free space monitoring are separate responsibilities. The demo also reserves each
machine’s own disks while it exists, within a 10 GiB worker budget.

## Come back with a different machine

The first `mix run` process has exited. Start a new one with the same environment:

```sh
mix run -e 'SmolBox.DurableHost.VolumeDemo.run("resume")'
```

This controller recovers the volume record from PostgreSQL. It creates a new
machine with a new identity, attaches the retained volume, and checks that
`kept.txt` still contains `original`. It then writes `replacement` into that file.

The next check matters too. After deleting the replacement, the demo creates a
third machine with `readonly: true` on its `VolumeMount`. That guest can read
`replacement`, but its attempt to overwrite the file fails.

| Point in the walkthrough | What the check proves |
| --- | --- |
| Original deleted | The volume remains unattached, with its reservation held. |
| New controller, new machine | The same file can be read and modified after the controller restart and machine replacement. |
| Read-only attachment | The guest can read the modified file, but cannot overwrite it. |
| Final cleanup | The machines and volume are deleted; disk and slot reservations are zero. |

A read-only mount is still **exclusive**. SmolBox allows one machine attachment
per volume, including stopped machines. It is not a way to share a cache among
several concurrent guests. Mounts are fixed at machine creation; there is no hot
attach or detach.

## Finish the data’s lifetime deliberately

The `resume` phase deletes its final machine before deleting the volume. In your
own application, the volume cleanup call uses the current record version:

```elixir
{:ok, record} = SmolBox.Volumes.inspect(runtime, volume)
{:ok, result} = SmolBox.Volumes.delete(runtime, volume, record.version)
# Only result.state == :deleted confirms completed cleanup.
```

This deletion removes the worker directory and its contents. SmolBox requires the
worker’s explicit acknowledgment before releasing the reservation. A lost response
or unavailable worker is not evidence that the files are gone. Upstream provides
no volume lookup endpoint for an independent API check afterward.

Deleted identity records remain for deduplication. Reusing an old ID will not
create a fresh, empty volume. Use a new ID and partition for a new demo run;
a refresh or restart should never quietly replace your data.

If a phase is interrupted, inspect its records before doing anything else. Do not
rerun the entire phase blindly or remove the store to get past an uncertain state.
The [recovery procedure][recovery] explains how to preserve evidence, quiesce pending
requests and explicitly resolve owned storage.

I ran this exact released demo on physical Linux with PostgreSQL and smolvm
1.22.0. Both phases passed in separate Elixir processes. I also checked the file
on the host between phases, verified the volume directory was gone afterward,
and stopped the dedicated worker and database. The [validation receipt][evidence]
records the checks and the initial setup failure caused by an incorrect volume
root. This proves the small walkthrough on that host configuration, not host quotas
or isolation across tenants.

## What this gives you, and what it does not

A local volume fits a project or cache that should survive replacing its machine
on one worker. You can rebuild the environment while keeping the files you chose
to retain. Your application owns when that data is finally removed.

It is **not a backup**. Losing the worker disk can still lose the data. There is no
replication or migration to another worker, and a replacement can modify or delete
files on a writable mount. Keep backups separately when the data matters.

It is also a different choice from [exports, checkpoints and branches][reuse].
Those mechanisms reuse supported machine state. A volume keeps a separate data
location alive. SmolBox 0.4.1 does not combine mounted machines with exports,
checkpoint capture or restore, branches, or disk expansion.

The useful question is simple: **does this data belong to the machine, or to the
project that will outlive it?** Put that decision in the lifecycle, then prove it
with a file you can afford to delete.

[example]: https://github.com/hfiguera/smolbox/tree/v0.4.1/examples/durable_host#local-volumes
[volumes]: https://hexdocs.pm/smolbox/0.4.1/local-volumes.html
[recovery]: https://hexdocs.pm/smolbox/0.4.1/local-volumes.html#uncertain-outcomes-and-recovery
[reuse]: ../exports-checkpoints-or-branches/

[evidence]: ../../media/replace-the-machine-keep-the-project/validation.json
