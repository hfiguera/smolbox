# smolvm 1.20.2 qualification

This checkout selects **1.20.2** on Linux x86_64 and macOS Apple Silicon.
Published SmolBox 0.3.0 and 0.2.1 keep their 1.19.0 default. Explicit older
supported runtimes remain available; no intermediate release is admitted merely
because its version lies between two qualified releases.

## Exact inputs

The comparison starts at the previously qualified `v1.19.0` and ends at official
[`v1.20.2`](https://github.com/smol-machines/smolvm/releases/tag/v1.20.2), source
commit `59a2c2677ab7d6bfe01d1f2261efbbeea4d7dfb8`. It covers 48 commits across
1.19.1, 1.19.2, 1.19.3, 1.20.0, 1.20.1 and 1.20.2. **Changes after that tag are
excluded**, including newer commits present in the local reference checkout.

Complete official archives and bundled component checksums were verified:

| Distribution | Archive SHA-256 |
|---|---|
| Darwin ARM64 | `6e3e9fe097f7cc5e1e6584c09a722cf58f7e40984fb840331beffdcbb4ca106d` |
| Linux x86_64 | `e5a2b139febb7ee38185c658521484f975c450d998192074e312d48a6c238cf5` |

The Linux worker runs directly on the physical development host, with no nested
virtualization. Its private service has an 8 GiB memory cap, no swap, a four-CPU
quota and a 256-task limit. PostgreSQL, registry and controllers are outside that
worker cgroup. Native macOS uses private worker and PostgreSQL directories.
Both use Elixir 1.20.4 / OTP 29.0.6 and working host `resize2fs`.
Linux reuses approved disk artifacts; macOS prepares fresh Python and Node disk
artifacts using the candidate. RAM checkpoints are captured on 1.20.2, never
relabelled from an older runtime.

## Changes that matter to SmolBox

- Registry manifest requests use the registry origin rather than an allowlist
  entry, validate JSON objects and preserve authentication, missing-object and
  rate-limit responses. Artifact verification caching, reuse of extracted
  layers and recovery of missing cached layers affect provisioning.
- Checkpoint parsing and backing storage changed, alongside bundled libkrun and
  libkrunfw. Restore, independent writes, deletion and later reuse therefore
  need live checks. macOS also receives a restored-disk branching fix.
- `.checkpoint` is the new upstream spelling; `.smolcheckpoint` remains accepted.
  SmolBox accepts both and keeps its existing managed capture filename. The
  contents and exact capture version determine compatibility, not the suffix.
- Stop can recognize a late guest exit after an unsuccessful acknowledgement.
  This is not proof of successful filesystem synchronization. SmolBox retains
  its ownership checks, uncertainty rules and evidence requirements for cleanup.
- Linux Landlock adds the refer right for moves within approved writable paths.
  Hostname matching gains explicit patterns, while legacy domain behavior stays
  compatible. SmolBox does not expose new pattern syntax or relax its policies.
- The eight-route OpenAPI subset adds `MachineInfo.runtime`. Linux and macOS
  schema exports match. SmolBox ignores this optional observation; live resize
  is not exposed and immutable resource reservations are not revised from it.
- Upstream batched branching requires `freezeSource=true`, no held child and no
  port mappings. SmolBox sends `freezeSource=false`, so those batch improvements
  do not establish a speedup for this API.

The implementation admits exactly 1.20.2 in the existing operation gates and
records the actual worker runtime in export receipts. It does not add pause,
resize, migration, embedded execution cancellation, automatic expiry or new
credential/interceptor APIs. Historical feature reports and performance figures
remain unchanged.

## Validation

The [receipt inventory](evidence/smolvm-1.20.2.json) records distribution hashes,
source hashes and bounded local log hashes. Hashes identify private evidence;
they do not make private lab logs downloadable. Contract tests use simulated
workers and are separate from the real-worker results.

The ordinary CI suite passed **538 checks** (four doctests, six properties and
528 tests), with 29 live tests excluded. Formatting, compilation, xref, Credo
including ex_slop, ExDNA, Credence and Dialyzer passed. The standalone maintainer
suite passed **25 tests**. PostgreSQL store contracts passed **59 tests** on both
platforms. The complete suite also passed on Elixir 1.18.4 / OTP 27.3.4.15
with zero failures and 29 live tests excluded. Current and minimum package consumers passed; ExDoc and local links
passed using the repository's `MIX_ENV=dev` documentation command.

| Real-worker check | Physical Linux x86_64 | Native macOS Apple Silicon |
|---|---|---|
| Ordinary execution with default selection | 9 passed | 9 passed |
| Contained security probes with 1 MiB file cap | 5 passed | Not repeated |
| PostgreSQL controller recovery | 25 passed | 25 passed |
| Checkpoint disk/RAM isolation and deletion | 3 passed, including `.checkpoint` path | 3 passed |
| Durable checkpoint recovery | 3 passed | 3 passed |
| Extended execution | 4 passed, including buffered and SSE 305-second commands | Not repeated |
| Terminal input, resize, exit, disconnect and slow consumer | 3 passed | 3 passed |
| Larger guest files and startup workload | 2 passed | 2 passed |
| Health/inspection during three active streams | 1 passed | Not repeated |
| Port mappings and outbound controls | 2 passed | 2 passed |
| Workspace acceptance across separate controller processes | Prepare and resume passed | Prepare and resume passed |
| API restart, unavailable worker, confirmed missing machine | 3 scenarios passed | 3 scenarios passed |
| OCI create, pull, list, controller recovery, stop/start and delete | Passed | Not repeated through public API |
| Managed branches and independent writes | 20 measured copies plus warmup; held release also passed | Two restored-source children passed |
| Export/checkpoint/branch/reuse composition | Complete five-mode campaign | Not repeated |

The workspace scenario verifies a background HTTP service separately from its
launch, a terminal, a 16 MiB file, reconnection to the same machine, stop/start
persistence and final absence/reservation release. Fault scenarios preserve an
unknown execution outcome, never replay the command, and verify cleanup only
after absence. The macOS branch scenario uses the memory store; durable branch
recovery across separate controller processes is exercised on Linux.

### Physical Linux provisioning repetition

The existing harness ran with `runtime_version: "1.20.2"`, 20 measured samples per
mode plus one warmup, rotating order and the same million-row synthetic workload.
All 439 recorded stages succeeded. Preparation, measurement and cleanup ran in
separate BEAM processes. Final inventory was empty and slots, CPU, memory and disk
reservations were all zero. The export receipt records **1.20.2**, and the capture
approval verifies its 1.20.2 metadata. Raw rows and summary are in the
[measurement evidence](evidence/smolvm-1.20.2-provisioning.json).

| Mode | Disk result median | RAM result median | RAM result p95 |
|---|---:|---:|---:|
| Fresh local artifact | 4.471 s | 4.678 s | 4.967 s |
| Prepared export | 0.780 s | 1.186 s | 2.158 s |
| Checkpoint restore | 0.671 s | 0.919 s | 1.018 s |
| Live branch | 0.663 s | 0.882 s | 0.993 s |
| Existing machine | 0.189 s | 0.412 s | 0.545 s |

These are a separate repetition of the [1.19.0 method](provisioning-performance.md),
not a randomized comparison between versions. The median ordering is similar;
the export p95 is higher in this run. These samples do not establish a universal
speedup or slowdown. Historical report and blog figures remain unchanged.
No nested Linux or macOS performance comparison was added.

The terminal disconnect probe revealed a real behavioral difference: its
intentionally detached Python child stopped on both 1.20.2 platforms. With the
same Python artifact on macOS 1.19.0, that child stayed active. The updated test
records both observations while still requiring an **unknown** terminal outcome
when no exit notification reached the client. One process tree is not a general
cancellation guarantee, and no work is automatically replayed.

Initial failed attempts are retained separately from successful runs: a Linux
liveness assertion hardcoded 1.19.0; the old terminal test expected its child to
survive; the new health fixture contains one running machine instead of zero;
a macOS pack helper inherited the intentionally small 16 MiB transfer cap; a
checkpoint invocation omitted its socket setting; and the first worker-fault
probe inherited the primary worker's Unix socket. A later fault probe exceeded
the helper's three-second stop deadline. Only that owned mutation now receives a
bounded 60-second budget; the complete fault scenarios then passed. An initial
macOS branch probe rejected an overlong test namespace, then a cleanup assertion
encountered a pre-existing temporary RAM file. The corrected run checks against
its recorded initial temporary-file inventory; both children and their source
were deleted and reservations released. An earlier failed probe's owned guests
were removed separately, not counted as successful managed cleanup. A transient
Linux service had to be recreated after stopping it to change the test file cap. These were corrected before
counting the relevant checks. Python's safe tar extraction also rejected the
archive's legitimate absolute guest-root symlinks; extraction was completed from
the digest-verified archive and all component checksums were checked afterward. A documentation invocation in
`MIX_ENV=test` also produced hidden-test-module warnings; the configured
`MIX_ENV=dev` documentation gate passed. The minimum-toolchain run initially
encountered an incompatible globally installed Hex archive; installing Hex and
Rebar in a task-local Mix home allowed the full suite to pass.

## Upgrade and rollback

Install the complete matching distribution, including its agent and VMM
libraries. Updating the Elixir dependency does not install or restart workers.
Pin a retained 1.19.0 worker explicitly with `runtime_version: "1.19.0"` before
adopting the new default. Keep controller configuration consistent across a
shared store and follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker).

No SmolBox SQL migration, store capability or codec revision is added. Existing
identities, creation specifications, ownership evidence and history are retained.
However, older readers can reject new checkpoint or export receipts carrying
`runtime_version: "1.20.2"`. Upgrade all readers before producing those records;
rolling back application code alone does not make them readable again.

Checkpoint approvals must retain their exact capture runtime, platform,
architecture and profile. Do not relabel a 1.19.0 checkpoint as 1.20.2. Changing
its filename does not convert it. Cross-version checkpoint restore, in-place
upgrades of retained worker state and rollback of the upstream worker database
are not qualified by these fresh-worker tests. Preserve disks, metadata, original
keys, approvals and ownership evidence before maintenance.

Qualification remains **`:development`**. This is not production isolation
certification or a new exhaustion campaign. Linux ARM64 and Windows are not
qualified. The existing one-command limit, retention and explicit cleanup rules
remain unchanged.

## Reproduction

Use a dedicated empty worker, private database, private artifact root and fresh
keys. Select `SMOLBOX_RUNTIME_VERSION=1.20.2`; install the verified complete
archive and provide the worker's actual socket or loopback URL. Follow
[scripts/ci/README.md](../scripts/ci/README.md) for ordinary, recovery, fault and
package checks. Focused suites cover `test/extended_runtime`,
`test/terminal_runtime`, `test/guest_files_runtime`, `test/workload_runtime`,
`test/ports_runtime`, `test/checkpoint_runtime` and `test/runtime_compatibility`.
Port tests need independently reachable positive and negative control endpoints.
The security suite expects the worker's 1 MiB transfer cap; the larger-file and
workspace checks require an explicitly approved 16 MiB cap.

The durable example's `release_acceptance_test.exs` uses separate `prepare` and
`resume` BEAM invocations with unchanged identity, keys and storage. The
[provisioning harness](../scripts/benchmarks/provisioning/README.md) accepts an
explicit `runtime_version` for export, checkpoint and branch checks on physical
Linux. Use a new partition; never replay a phase with an uncertain outcome.
Export evidence before stopping only the campaign's own services. Nested-lab
scripts have updated version pins but were not run in this direct-Linux campaign.
