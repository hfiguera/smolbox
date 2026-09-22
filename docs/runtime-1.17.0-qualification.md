# smolvm 1.17.0 qualification

Status: **1.17.0 passed the live campaign and is the default in this unreleased
checkout. Explicit 1.16.1 support remains.** Published 0.1.5 is unchanged.

The candidate is the official v1.17.0 release, commit
`d33b5a4adeb844365922cd2a29a89d93a94008ad`. The external reference checkout at
`73d4b480dc703c86b676bb54f72318ef94f24e6a` has the same source tree. Qualification
covers Linux x86_64 in the disposable nested KVM lab reached through `ssh linux`
and native macOS Apple Silicon. It does not add Linux ARM64 or Windows support.

## Inputs and API review

| Distribution | SHA-256 |
|---|---|
| Darwin ARM64 | `93829b337541e96780090755346221bb23fbf36f688e39c8008792c8affea84b` |
| Linux x86_64 | `b648e6aa47dc4fee1ddc255f5c11401fc6aab41bab61335bde903ad2fc2e1bd1` |

Archives match the release asset digests. Both complete distributions passed
bundled component checksum checks. The Linux candidate startup preflight also
pins the executable, libkrun, guest agent and prepared images. Both platforms
use the repository's Elixir 1.20.4 / OTP 29.0.6 toolchain. Existing approved Python
and Node artifacts are reused to check compatibility with previously prepared
images.

Compared with 1.16.1, the OpenAPI schemas shared by both versions are unchanged.
The file GET route now returns `application/json` for a directory, with an
`entries` array, and `application/octet-stream` for an ordinary file. SmolBox's
binary download contract continues rejecting directory JSON. No directory
listing public API is added by this qualification.

The new persistent resolver refresh must preserve network policy through reuse
and stop/start. Shutdown signal diagnostics do not prove completed synchronization
or fence previously sent requests. Ownership verification, unknown-outcome
blocking, explicit operator quiescence and verified deletion remain required.

## Campaign and evidence

The campaign separates ordinary runtime, controller recovery, checkpoint,
persistent-machine, network and worker-fault checks. Deterministic tests and
PostgreSQL store contracts do not count as real-worker qualification.

Completed real-worker candidate checks:

| Check | macOS ARM64 | Linux x86_64 |
|---|---|---|
| Ordinary/runtime cases | 9 passed | 14 passed, including security characterization |
| PostgreSQL controller recovery | 25 passed | 25 passed |
| Checkpoint execution | 3 passed | 3 passed |
| PostgreSQL checkpoint recovery | 3 passed | 3 passed |
| Persistent machine across independent BEAMs and stop/start | Passed | Passed after example conflict-handling correction |
| Network policies before/after restart | Offline, CIDR, hostname passed | Offline, CIDR, hostname and managed policy passed |
| Worker restart/unavailable/missing | 3 passed | 3 passed |

The candidate also passed `mix ci`: 257 tests, 17 runtime exclusions, formatting,
warning-clean project compilation, cycle checks, Credo/ex_slop, ExDNA, Credence
and Dialyzer. The standalone CI tooling suite passed 23 tests; the real PostgreSQL
store suite passed 27 tests with 28 runtime tests excluded.

Native macOS runs only ordinary compatibility and controlled recovery cases.
Security-characterization and full-storage probes run in the bounded Linux lab.
The latter retains the existing preservation/disposal contract: completed
work may discard its VM, while uncertain work must not lose retained evidence or
capacity merely because graceful stop failed.

An initial macOS harness used the operating system's long temporary directory.
libkrun refused its control socket with `path must be shorter than SUN_LEN`.
That run passed only one of nine cases. The failed machines never started; their
records were removed from the dedicated worker after inspection. Moving the
private worker root to a short `/tmp` path allowed all nine ordinary runtime
cases to pass. Operators must keep worker state paths short enough for Unix
socket limits; a generic startup EINVAL alone does not identify this cause.

The first Linux persistent `resume` reached a concurrent record update between
inspection and stop, and failed with `stale_version` / `not_dispatched`. The
example now refreshes and retries only that rejected store conflict for up to
five seconds. Other errors, including uncertain worker requests, are returned
without retry. A fresh two-process acceptance run passed after this correction. The
failed run was stopped by disposable-lab teardown, not recorded as successful
managed deletion or reservation release.

Linux also passed both 768 MiB cache-exhaustion probes: completed work deleted
its machine with verified absence and reservation release; uncertain work kept
a running machine, unknown outcome and reservation after failed stop, with no
DELETE request. External lab teardown of that retained synthetic VM is separate
from managed cleanup. Shared-registry filesystem exhaustion was not rerun.

## Default selection and final checks

After the candidate campaign passed, this branch changed `WorkerConfig`,
`Checkpoint`, maintainer preflight and example defaults to 1.17.0. Explicit
1.16.1 support remains. All 49 production modules match the qualified candidate's
executable AST after normalizing the two version defaults and removing docs and
source metadata; the example conflict correction was separately rerun live.

With `SMOLBOX_RUNTIME_VERSION` removed, nine ordinary macOS runtime cases,
three checkpoint cases and the two-process persistent acceptance passed. The
Linux two-process persistent acceptance also passed without the override. Both
finished with the same original machine deleted, verified absence, released
reservations and empty worker inventory. Linux had no remaining candidate KVM
descriptors; its outer lab was stopped. The private Mac worker and temporary
PostgreSQL were also stopped.

Final `mix ci` passed 259 cases (17 runtime exclusions), all configured quality
checks and Dialyzer. Standalone tooling passed 23 cases. The corrected durable
example passed Dialyzer. ExDoc built without warnings, and local links/fragments
passed across 53 pages. Current and minimum dependency consumers passed against
the same package archive with the final executable code. The evidence receipts
and guide wording were finalized afterward; this is not a published release or
a claim of a new protected GitHub workflow run.

The [evidence JSON](evidence/smolvm-1.17.0.json) records source hashes, distribution
and image identities, results, log digests, initial failures and limitations.
Raw synthetic logs remain in the maintainer's ignored `.local/qualification-1.17.0/`
directory; checkpoint RAM, database files and private keys are not published.

## Reproducing the checks

Use the pinned toolchain and dedicated worker/database environments described in
`scripts/ci/README.md` and the durable example. Set `SMOLBOX_RUNTIME_VERSION=1.17.0`
for candidate testing; unset it to check the default. Run `mix ci` and
`elixir scripts/ci_test.exs`, then the platform-appropriate runtime tests:

- Linux disposable lab: `mix test test/runtime --include runtime --warnings-as-errors`.
- Native macOS: `mix test test/runtime/client_runtime_test.exs test/runtime/managed_runtime_test.exs --include runtime --warnings-as-errors`.
- Prepared matching checkpoint: `mix test test/checkpoint_runtime --include runtime --warnings-as-errors`.
- Durable example: `mix test test/recovery_runtime_test.exs test/checkpoint_recovery_runtime_test.exs --include runtime --warnings-as-errors`.
- Durable persistent acceptance: run `mix run scripts/persistent_machine.exs prepare`, then `resume` in a separate BEAM with the same database, partition, identity and keys.

Run networking, wire capture and storage probes through `scripts/lab` in their
prescribed environments. Storage exhaustion belongs only in the disposable Linux
lab. Each probe must start with its own candidate state; preserve reports before
resetting the lab. The `worker-fault` CI command separately covers restart,
unavailable and missing scenarios with a dedicated worker wrapper.

## Upgrade boundaries

Changing the declared runtime version does not install or upgrade a worker.
Install the complete matching distribution, including its guest agent and
hypervisor libraries, and provide working host `resize2fs`. Qualify file
preservation on the deployment's actual disks and prepared artifacts.

Keep existing fleets explicitly pinned during rollout. Quiesce controllers and
outstanding worker requests before changing worker binaries. A controller restart
or an observed stop alone does not fence old requests. Preserve the durable store,
keys, ownership evidence, machine disks and resource reservations.

Checkpoints must be prepared and approved for their declared runtime version;
this campaign does not establish cross-version checkpoint portability. Continue
explicitly declaring 1.16.1 for existing 1.16.1 approvals and workers. Never
silently relabel an old checkpoint as 1.17.0. This work adds no migration,
replication, worker-disk restoration, production isolation certification or
performance guarantee.

The live runs create machines with 1.17.0 and reuse existing prepared images.
They do not establish an in-place binary upgrade of an already retained 1.16.1 VM.
Keep those deployments explicitly pinned until their maintenance procedure has
been qualified; preserve their durable identity and disks throughout.
