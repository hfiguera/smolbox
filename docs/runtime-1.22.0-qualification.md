# smolvm 1.22.0 qualification

This campaign compares the previously qualified **1.20.2** with the official
**1.22.0** release on physical Linux x86_64 and native macOS Apple Silicon.
This checkout retains **1.20.2** as the default. Version **1.22.0** requires
explicit configuration while the macOS creation failure described below remains
unresolved. Qualification remains `:development`. Published SmolBox 0.4.0 also
selects 1.20.2;
updating a library never installs or upgrades its workers.

## Exact inputs

The source range is `v1.20.2` (`59a2c2677ab7d6bfe01d1f2261efbbeea4d7dfb8`)
through [`v1.22.0`](https://github.com/smol-machines/smolvm/releases/tag/v1.22.0)
(`f40f42c337319b724e221e8d3f809f7b186340c2`): 21 commits across 1.21.0,
1.21.1 and 1.22.0. Changes after that tag are excluded. Only 1.22.0 is admitted;
intermediate versions are not implicitly supported.

Official archive digests match the release asset metadata. Bundled component
checksums were verified before starting the workers:

| Distribution | Archive SHA-256 |
| --- | --- |
| Linux x86_64 | `00d2f057c963ff950846d4059af87bdddb7edf707750cdab863cb0879d6b339e` |
| Darwin ARM64 | `8e6f9d7adf9ee87afe59f8c30d81da5be0c2546f53de7275e7eea2eb39d8f186` |

The Linux worker runs directly on the physical development host, with KVM and
no nested virtualization. Its private service has an 8 GiB memory limit, no swap,
a four-CPU quota and a 256-task limit. The bounded security probes use a separate
private worker with a 1 MiB file cap, 4 GiB memory limit and two-CPU quota. Other
file-transfer tests use 16 MiB. PostgreSQL and controllers are separate from the
worker services. macOS uses a private worker home, database and Unix socket.
Both platforms use Elixir 1.20.4 / OTP 29.0.6 and host `resize2fs`.

Disk artifacts retain their approved hashes. Checkpoints are captured with
1.22.0, rather than relabelling a capture made by an older runtime.

## Changes relevant to SmolBox

- Execution waits for process-exit notifications and drains output through a
  bounded channel. Guest command wrappers also changed. Exit codes, binary
  output, streaming, timeouts and terminal outcomes need live regression checks.
- Layered checkpoint restore can add a private copy-on-write top instead of
  copying the previous top layer. Extraction hashes shared artifacts as it
  extracts them. These changes affect isolation, backing dependencies and cleanup.
- Restored VMM UID assignment uses the restored machine's own directory. The
  unprivileged Linux campaign does not establish root-worker UID isolation.
- macOS memory checkpoints are streamed sparsely. This is relevant to capture
  correctness and host storage, but this campaign does not publish a new macOS
  performance comparison.
- Eligible fresh OCI machines can use a shared image seed, including on macOS.
  Seed creation resolves registry metadata on the host and uses a temporary
  network-enabled builder. The ordinary 1 GiB profiles skip that path; packed
  artifacts and checkpoint restores use different paths. Host registry access,
  builder resources and retained caches need their own operator budget. Guest
  outbound policy does not constrain host-side preparation. Operators can use
  `SMOLVM_IMAGE_SEEDS=0` when that preparation does not fit their deployment policy.
- Recent incremental checkpoint materializations can be cached. The new
  `checkpoint-warm` command is a CLI operation, not a new SmolBox HTTP API or a
  guarantee that every managed capture uses the cache. Cache eviction targets
  are not hard limits on all retained host storage.
- Configurable graceful shutdown affects the HTTPS server path. It does not
  replace SmolBox's durable admission draining or fence requests already sent.
- Empty JSON start bodies are accepted. SmolBox already sends a JSON object.
  Upstream `stop_on_exit`, Windows support and embedded SDK changes add no new
  SmolBox API or qualified platform in this change.

The full exported schemas match across platforms. SmolBox's eight selected
paths and 21 referenced schemas are unchanged from 1.20.2. Wire captures retain
actual binary execution bytes, SSE framing and lifecycle responses.

## Validation

The [receipt inventory](evidence/smolvm-1.22.0.json) records release, source,
fixture and local log hashes. Those hashes identify private evidence; they do not
make private lab logs downloadable. Contract tests use simulated workers and are
separate from the real-worker checks below.

The ordinary CI suite passed **608 checks** (four doctests, six properties and
598 tests), with 29 live tests excluded. Formatting, compilation, xref, Credo
including ex_slop, ExDNA, Credence and Dialyzer passed. The maintainer suite passed
**25 tests**. PostgreSQL store contracts passed **78 tests** on each platform.
The ordinary suite also passed on Elixir 1.18.4 / OTP 27.3.4.15 with no failures
and 29 live tests excluded. Current and minimum package consumers passed, including
the minimum Elixir/OTP pair. Both maintained example apps passed compilation,
Credo/ex_slop, ExDNA and Dialyzer. ExDoc and local link checks passed.

| Real-worker check | Physical Linux x86_64 | Native macOS Apple Silicon |
| --- | --- | --- |
| Ordinary execution, measurements and capacity | 9 passed | 9 passed |
| Contained security probes with 1 MiB file cap | 5 passed | Not repeated |
| PostgreSQL controller recovery | 25 passed | 25 passed |
| Checkpoint disk/RAM isolation and deletion | 3 passed | 3 passed |
| Durable checkpoint recovery | 3 passed | 3 passed |
| Extended execution | 4 passed, including buffered and SSE 305-second commands | Not repeated |
| Terminal input, resize, exit, disconnect and slow consumer | 3 passed | 3 passed |
| Larger guest files and startup workload | 2 passed | 2 passed |
| Health/inspection during three active streams | 1 passed | Not repeated |
| Port mappings and outbound controls | 2 passed | 2 passed |
| Workspace acceptance across separate controllers | Prepare and resume passed | Prepare and resume passed |
| API restart, unavailable worker, confirmed missing machine | 3 scenarios passed | 3 scenarios passed |
| OCI create, pull/list, controller restart, stop/start and delete | Passed with x86_64 platform manifests | Passed with ARM64 platform manifests |
| Disk expansion and guest file preservation across controllers | 2/2 to 4/3 GiB passed | 2/2 to 4/3 GiB passed |
| Retained volumes, replacement machine, read-only attachment and cleanup | Passed with PostgreSQL | Unsupported platform |
| Durable draining, retained work and explicit resume | Passed across controllers | Not repeated |
| Managed branches and independent writes | Five measured children plus warmup; held release passed | Two restored-source children passed |
| Export/checkpoint/branch/reuse composition | Five samples per mode plus warmup; cleanup passed | Not repeated |

The workspace scenario verifies a background HTTP service separately from its
launch, terminal input/resize/exit, a 16 MiB file, reconnection to the same machine,
stop/start persistence and final absence/reservation release. Fault scenarios keep
unknown command outcomes without replay. Terminal disconnect continues to produce
an unknown outcome even though the tested child stopped; that observation does
not establish a general cancellation or fencing guarantee.

OCI runs use the 20 GiB storage profile that is eligible for image seeding, and
both hosts retained a seed cache. The cache and temporary builder are upstream
preparation resources, not additional SmolBox reservations. These tests do not
qualify private OCI registry authentication, cache exhaustion or cross-tenant seed
isolation. The macOS branch scenario uses the memory store; Linux covers durable
composition. Historical timing comparisons are unchanged: this is a correctness
campaign, not a new performance claim.

### Failed attempts and follow-up

- The first combined feature runs used the older terminal child-liveness
  expectation. The version-specific assertion now includes 1.22.0; unknown-outcome
  expectations are unchanged. Focused terminal tests passed on both platforms.
- One initial macOS Node creation returned HTTP 500. The response body was not
  retained and the worker warning log only records the status and latency.
  Three fresh-worker/cache creations and the original complete feature rerun
  passed. The investigation below adds evidence but does not establish a cause.
- The first Linux composition run timed out **before submitting start**, waiting
  for `created`. Its retained record had `state: :stopped`, no active operation
  and no lifecycle request; the create response itself was `created`. The
  benchmark assumption was wrong. The investigation below reproduces the
  transition on both versions and fixes that wait. The failed run's owned
  resources were cleaned through verified operations. A subsequent complete
  five-mode run passed five samples per mode plus warmup, with zero reservations.
- The first macOS OCI probe mistakenly supplied the Linux x86_64 platform digest
  while declaring ARM64. The worker returned an exec-format error. Native pinned
  ARM64 manifests passed. Source architecture is an operator approval, not a
  remotely verified property of a supplied digest.
- Initial harness attempts needed the database migrated, correct socket/environment
  settings and the minimum toolchain's own Hex/Rebar installation. These setup
  failures are retained in the private evidence and are not counted as passes.

### Investigation outcome

**Linux: confirmed benchmark race, not a 1.22.0 start regression.** The upstream
supervisor checks machines every five seconds. An unstarted machine has no live
manager; with restart policy `never`, the supervisor records it as `stopped`.
The supervisor source is unchanged between v1.20.2 and v1.22.0. Two fresh machines
per version reproduced `created` → `stopped` after six seconds without a start
request on physical Linux. Every machine then started explicitly, ran a command,
and was deleted with verified absence. Ownership identity remained unchanged.

The provisioning harness now accepts confirmed `created` or `stopped` with no
pending operation before submitting start. It still requires confirmed `running`
afterward. Two deterministic contract tests, one per version, hold the create
response while the worker observation changes to `stopped`; they verify that no
start was sent, explicit start succeeds and deletion releases the reservation.
These tests use the simulated worker; the four reproductions used official live
Linux binaries.

**macOS: unresolved, so default promotion is deferred.** An instrumented replay
of the original 14-test feature sequence with seed 194898 passed. The proxy
captured HTTP response status and error bodies; its only HTTP 500 responses were
expected file-read failures, with no create failure. A separate alternating
Python/Node workload completed 12 create/start/exec/stop/delete cycles on 1.22.0
and 12 on 1.20.2. Both final inventories were empty. The probes used native Apple
Silicon and official binaries with separate private worker homes.

The original Node request used a `.smolmachine` pack, which does not take the new
image-seed preparation path. That rules out attributing this failure to that path
without further evidence. Host disk logs did not establish a cause. Passing
replays do not establish whether the original failure was environmental or a
worker defect, nor do they prove a fix. No retry was added to hide creation errors.

The remaining diagnostic requirement is the **actual create-error response body**
and corresponding worker/host logs if the failure recurs. Private investigation
scripts and logs were retained with hashes in
[`smolvm-1.22.0-investigation.json`](evidence/smolvm-1.22.0-investigation.json).
All investigation machines were deleted and their private workers stopped.
The earlier campaign receipt remains historical; its source hashes and counts
refer to commit `4c9a8ee`, before this investigation and default reversal. Follow-up validation passed 610
ordinary checks (29 live tests excluded), all `mix ci` quality gates, 25 maintainer
tests, package consumers on current and minimum toolchains, and local links in
127 generated documentation pages.

### Additional macOS investigation

A second investigation completed 50 alternating Python/Node machine lifecycles
on the official 1.22.0 binary. Private instrumentation captured HTTP errors and
forwarded each `hdiutil` command while recording its status and stderr. All 50
lifecycles and all 250 disk-image commands succeeded.

Three further runs replayed the original 14-test sequence and seed, restoring the
old terminal assertion in a private test copy. This deliberately reproduces the
earlier assertion failure and its `on_exit` cleanup path. Each run had 13 passes
and that one intentional assertion failure; Node creation succeeded in all three.
These are diagnostic runs, not three clean test-suite passes. The instrumentation
can affect timing, so it does not exclude a timing-dependent failure.

Recovered disk-image, APFS and kernel logs from the original failure window did
not identify an error that could be tied conclusively to the create request.
**The original macOS root cause remains unproven.** Its error response was not
retained, and the failure has not recurred with response capture. No speculative
runtime fix or automatic create retry was added. The 1.20.2 default stays in place.
Both additional private worker inventories were empty before shutdown.

## Limits

No Windows, Linux ARM64, nested Linux, root-worker UID isolation, hostile
multi-tenant certification, cache resource bounds, in-place retained-worker
upgrade, worker database rollback or cross-version checkpoint restore is claimed.
macOS extended commands were not repeated. Qualification remains development-only;
it does not attest production containment or automatic recovery of lost disks.

All campaign-owned machine inventories were empty before shutdown. The private
workers, bridges, Linux registry and both PostgreSQL instances were stopped;
other applications and workers were left running. Capture/branch allowances were
released only after the tested cleanup evidence, and the final Linux composition
reported zero slots, CPUs, memory and disk reservations. Retained worker caches
remain distinct from machine inventory and reservations.

## Upgrade and rollback

Explicit configuration of previously supported versions remains available.
Worker health must match the selected version exactly; newer versions are not
accepted by comparison or by a version range.

No SQL migration, store callback change or codec revision is introduced. Existing
controllers and readers can nevertheless reject records containing the new
runtime version, including checkpoint and export results. Upgrade all readers
before creating those records and account for retained history when rolling back.
Deletion does not erase that history.

Keep existing checkpoint approvals pinned to their capture version and retain
that runtime for restoration. New 1.22.0 captures must be approved as 1.22.0;
renaming a file or editing an approval does not establish cross-version support.
Stop and inspect retained machines before replacing a worker binary, and keep
ownership and capacity records intact. Shared caches and artifact backing files
are not released merely because a command finishes or a worker's inventory is
empty.
