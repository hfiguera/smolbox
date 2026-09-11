We filled a worker's disk while testing SmolBox. The machine stopped, but
deleting it failed: cleanup needed to update a database on the same full
filesystem.

We wrote about the failure. SmolVM's maintainer responded, changed the deletion
sequence, and pointed us to a new release. Then we returned to the lab to check
what had changed.

That exchange is worth sharing. It shows how work on an Elixir library can
help improve the runtime beneath it, and how contributing to open source can
include reproducing a failure and verifying someone else's fix.

## The failure was in cleanup

[SmolBox][smolbox] manages execution on SmolVM workers from Elixir. SmolVM
provides the microVMs; SmolBox tracks execution identity, outcomes, collected
files and cleanup. Our [previous article][previous-post] described testing that
integration under resource pressure in a disposable Linux lab.

One experiment exposed an awkward dependency. VM files and the worker's
registry shared a filesystem. Once the workload filled it, the worker could
stop the machine, but deletion needed a database commit. The operation that
would free space could not finish because there was no space to record it.

The worker logged:

```
commit vm removal: database or disk is full
```

The machine remained in inventory. Stopping it had not removed its resources,
and retrying deletion did not resolve the storage problem.

Our immediate correction was at the deployment level: give control metadata
its own storage capacity. That allowed cleanup when VM storage filled in the
later experiment. It left the behavior on a shared filesystem unchanged.

## BinBin changed the deletion order

After we shared the article on X, [BinBin He][binbin-x], the creator and maintainer
of SmolVM, replied that he would fix cleanup. He later came back with a release and
explained the change: perform the operation before recording it, so a full
filesystem would not prevent the operation itself.

The concrete change is in [upstream PR #1219][upstream-fix]. In the HTTP API's
deletion path, SmolVM now removes the machine's data before committing removal
of its registry entry. Releasing the VM files gives the database space to
complete its transaction when both share the full filesystem.

<figure>
  <picture>
    <source media="(max-width: 600px)" srcset="../../media/from-a-full-disk-to-an-upstream-fix/deletion-order-mobile.svg" width="390" height="670">
    <img src="../../media/from-a-full-disk-to-an-upstream-fix/deletion-order.svg" width="1200" height="520" alt="On a full shared filesystem, the old deletion path tried the registry write before freeing VM data and failed. The revised path frees VM data first, then writes the registry removal using the space released.">
  </picture>
  <figcaption>The relevant ordering change in the HTTP deletion path. This simplifies the operation to show its storage dependency.</figcaption>
</figure>

BinBin implemented the fix, which shipped in [SmolVM 1.14.6][upstream-release].
Our part was documenting the failure and testing the released behavior through
SmolBox. The source and patch were available for inspection, so we could
connect the observed failure to the operation that changed.

This ordering addresses a particular cleanup dependency. It is not a general
rule to perform every operation before recording intent. SmolBox still needs
durable execution identity before dispatching work that must not be silently
repeated.

## Back to the same full filesystem

A successful delete on an empty worker would not test this fix. We needed VM
data and registry metadata to compete for the same exhausted storage again.

The [targeted comparison][cleanup-results] ran the official SmolVM 1.14.1 and
1.14.6 distributions inside the disposable nested Linux lab. Both used the
same workload and layout: a **512 MiB tmpfs shared by VM data and the registry**.
We verified that the paths belonged to the same filesystem.

The guest performed bounded writes and flushed each one until storage filled.
We did not use a host process to pad the filesystem afterward. The shared mount
reached its full capacity on both versions. Stopping the machine released one
4 KiB block in each case, which we recorded rather than hiding the difference
between the state after writing and the state before deletion.

| Observation | SmolVM 1.14.1 | SmolVM 1.14.6 |
|---|---|---|
| Shared storage after guest writes | Full | Full |
| Stop | Succeeded | Succeeded |
| Delete through the API | Client outcome uncertain; worker logged the database storage error | Succeeded in three completed trials |
| VM data afterward | Remained allocated | Directory absent; only 184 KiB of the shared mount remained used |
| Restart and another execution | Required teardown of the owned environment | Deleted VM stayed absent; another execution and its cleanup succeeded |

The last row was part of the test. After deletion we restarted the worker,
checked that the old machine remained absent, then created another machine.
It passed file upload, command execution, download, stop and deletion.

That gave us evidence beyond a successful response: storage was released,
the deletion survived a worker restart, and the next execution could proceed.
We preserved the baseline failure and the test setup corrections alongside
the successful trials.

The comparison used two complete released distributions, so it does not isolate
every difference to one patch. The source change explains the relevant ordering;
the trials confirm the resulting behavior in this shared storage configuration.

## A verified fix still needed an upgrade decision

The cleanup retest answered one question. Making a new runtime the default
for SmolBox also required checking its other behaviors.

We followed with broader compatibility and recovery work on Linux and native
macOS Apple Silicon. That included execution, files surviving VM stop and
restart, durable recovery and explicit support for the older worker version.
Exhaustion and adversarial testing stayed in the disposable Linux lab.

The Mac work also found a preparation requirement worth documenting: disk
requests smaller than SmolVM's bundled templates need working host `resize2fs`.
Without it, our initial setup lost a file after stop and restart. With the
documented dependency available, the unchanged persistence test passed.

[SmolBox 0.1.2][smolbox] now defaults to SmolVM 1.14.6 on the tested Linux and
macOS platforms. Existing 1.14.1 workers remain supported through explicit
configuration. The [compatibility guide][compatibility] records the prerequisites
and results; updating the Elixir dependency does not upgrade a worker for you.

The deletion fix also leaves reasons to protect control storage. A separately
full metadata filesystem, a failing disk or a permission error presents a
different problem. Our results cover the configuration we exercised, and the
deployment still needs a recovery path.

## Contribution continues after the patch

The useful sequence here was straightforward: describe a failure, show the
conditions that produce it, inspect the upstream change, and return with
evidence from the released version. We could do that across an Elixir library
and a runtime written in Rust without maintaining a private fork.

For someone integrating an open source dependency, that is a practical way to
contribute. Include the version, the operation that failed and the relevant
environment. Keep the reproduction bounded. When a fix arrives, check the
original failure conditions and what happens afterward. Report what worked
and anything still unresolved.

Thanks to BinBin for responding and implementing the change. The result was a
fix available to other SmolVM users, plus a regression test we can run again when
the runtime changes.

A failed cleanup became a shared improvement because the conversation
continued through implementation and verification. Watching the next execution
succeed was the satisfying part.

[smolbox]: https://hex.pm/packages/smolbox/0.1.2
[previous-post]: ../testing-smolbox-with-nested-kvm/
[binbin-x]: https://x.com/binsquares
[upstream-fix]: https://github.com/smol-machines/smolvm/pull/1219
[upstream-release]: https://github.com/smol-machines/smolvm/releases/tag/v1.14.6
[cleanup-results]: https://hexdocs.pm/smolbox/0.1.2/resource-qualification.html#shared-storage-cleanup-retest
[compatibility]: https://hexdocs.pm/smolbox/0.1.2/compatibility.html
