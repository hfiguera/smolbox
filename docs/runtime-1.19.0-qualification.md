# smolvm 1.19.0 qualification

Status: **Real-worker qualification passed. Default in this checkout: 1.19.0.**
Published SmolBox 0.2.0 is unchanged. This report distinguishes the candidate
checks from the historical [1.17.0 campaign](runtime-1.17.0-qualification.md).

## Inputs and scope

The candidate is the official `v1.19.0` release, source commit
`572bb694d7dc6857d5de012c9e24a6e4a857ca27`. The later cascade-delete change on
upstream main is excluded. Both complete archives match GitHub's release asset
digests; their bundled component checksums are checked separately.

| Distribution | Archive SHA-256 |
|---|---|
| Darwin ARM64 | `8b2eaafdf15734b87a9f92aa837c79afa8bb351e183b7cd4f2205ffcd0f0cc85` |
| Linux x86_64 | `4feb274fd24d4722d718b9c85881fb9bba3c0c9f8123f67584436065bf583311` |

Tests use native macOS Apple Silicon and the disposable nested KVM Linux x86_64
lab reached through `ssh linux`, with Elixir 1.20.4 / OTP 29.0.6. Ordinary macOS
checks use private worker and PostgreSQL directories. Linux retains the existing
worker resource limits, enforced seccomp/Landlock, and isolated networking.
Existing prepared Python and Node artifacts are reused. No Linux ARM64, Windows,
production isolation certification, or performance guarantee is added.

## Upstream changes relevant to this qualification

The HTTP schema subset used by the client has the same eight routes. Create adds
optional credential bindings and guest subnet; start adds an optional external
interceptor. Existing required response fields are unchanged. The full Linux
and macOS exports match. New wire captures verify lifecycle observations,
buffered bytes, SSE framing and rejection of directory JSON as a binary file.

Upstream changes Linux process-exit detection, guest-agent work scheduling and
connection retries, worker SQLite contention, systemd scope recovery, libkrun,
and checkpoint restoration. Linux checkpoint restore can now share an immutable
base beneath a private writable disk. Independent restores must still isolate
writes, preserve RAM/files, and delete without damaging later restores. This
qualification does not reduce conservative disk reservations based on physical
sharing or claim that retained backing storage has disappeared after one delete.

Pause/resume is **not** exposed. `paused` and `pausing` observations remain
unsupported and fail decoding. Contract tests require rejection before command
dispatch, retention of the machine's reservation, and rejection of subsequent
commands and stopped-machine resolution. Do not pause a SmolBox-owned machine
through another tool. An observed stop, store fencing or a controller restart
still cannot fence requests already sent to the worker.

Credential substitution, external interceptors, checkpoint history/capture,
object-storage uploads, custom subnets and fork pools remain outside this
change. Workload logs remain console diagnostics; automatic workload restart
policies remain rejected. A responsive VM or successful terminal handshake does
not establish application readiness.

## Validation

The final ordinary CI suite passed **374 tests** (including four doctests and six
properties), with **29 real-worker tests excluded**. Formatting, compilation with
warnings as errors, xref, Credo, ex_slop, ExDNA, Credence and Dialyzer passed. The
standalone maintainer tooling suite passed **23 tests**. These use simulated
workers and are separate from real-worker qualification.
Real-worker results are recorded separately for each platform. The captured
[receipt inventory](evidence/smolvm-1.19.0.json) binds the source, distributions,
prepared artifacts and local log hashes to this campaign. Hashes identify evidence;
they do not make private lab logs publicly downloadable.

| Check | macOS Apple Silicon | Linux x86_64 |
|---|---|---|
| Ordinary real-worker execution | 9 passed | 14 passed |
| PostgreSQL controller recovery | 25 passed | 25 passed |
| Checkpoint isolation and deletion | 3 passed | 3 passed |
| Durable checkpoint recovery | 3 passed | 3 passed |
| Store contract | 36 passed | 36 passed |
| Long execution, terminal, files and workloads | 9 combined cases passed | Separate feature campaigns passed |
| Long execution beyond 300 seconds | Buffered and managed SSE passed | 4 cases passed, including both 305-second commands |
| Three active streams plus health/inspection | 1 passed | 1 passed |
| Integrated workspace, separate controller processes | Prepare and resume passed | Prepare and resume passed |
| Port mappings and background HTTP recovery | Integrated acceptance passed | Dedicated campaigns passed |
| Offline, CIDR and hostname policy across restart | Passed | Passed, including managed policy |
| API restart, unavailable worker, confirmed missing machine | 3 scenarios passed | 3 scenarios passed |
| Full cache, known exit and unknown outcome | Not run | Both accounting scenarios passed |

The integrated scenario creates a machine, writes and reads files, launches a
background service, exercises its terminal, reconnects from a new controller
process, stops and starts the same machine, reads the persisted bytes, and deletes
it. Both platforms verified absence and released machine/port reservations.
A background launch is not treated as proof of application readiness: the
acceptance scenario checks an HTTP response separately.

The initial Linux ordinary runtime and durable recovery phases passed 14 and 25
tests respectively. Their bounded pass receipts and output hashes were captured
on the development host. The lab later reached its automatic 45-minute deadline
and reset; the detailed inner logs from those phases were not exported. Later
phases export their logs after completion. The reset is not counted as successful
SmolBox deletion or reservation release.

Initial harness corrections included supplying the current cached dependencies
to the network-isolated Linux guest and giving the private macOS artifact root
its required mode 0700. An initial contract run referenced the new health fixture
before wire capture; another asserted an unknown execution where rejection before
dispatch correctly records a failed execution with `not_dispatched`. These are
recorded as failed setup/assertion attempts, not runtime passes. An initial
liveness probe requested eight streams from the client's four-connection pool
and exhausted pool checkout. The corrected probe leaves one connection for
observations; it does not claim to reproduce upstream's agent saturation limit.

The isolated Linux cache exhaustion probes use a 768 MiB filesystem. With a
known command exit, cleanup verifies absence and releases the reservation even
when the cache is full. With an unknown outcome and a failed stop, the probe
requires the machine and reservation to remain, with no delete request. That VM
is removed by external lab teardown, which is not recorded as managed cleanup.
This campaign does not repeat registry/data filesystem exhaustion on the host.

After changing the default, probes ran with `SMOLBOX_RUNTIME_VERSION` unset:
macOS passed nine execution tests, three checkpoint tests and persistent
prepare/resume; Linux passed persistent prepare/resume with the same identity,
verified absence and reservation release. An AST comparison confirms all 71
library modules differ from the live-tested candidate only in documentation and
runtime defaults. The first Linux default attempt used stale source after a
failed transfer and failed admission; the corrected fresh run passed.

## Upgrade and rollback

Installing a new Elixir dependency does not upgrade a worker. Install the complete
matching smolvm distribution, including libkrun and the guest agent, and provide
working host `resize2fs`. Keep existing workers explicitly pinned to their actual
version until their maintenance procedure is ready. Unknown versions and
unqualified intermediate 1.18.x versions are not admitted automatically.

This change introduces no SmolBox store capability, codec revision, SQL migration,
or public operation. Existing durable identities, ownership checks, cancellation,
unknown-outcome retention and verified deletion remain unchanged. Applications
must still coordinate worker configuration across controllers sharing a store.

Checkpoint approvals must retain the exact capture runtime. Do not relabel a
1.17.0 checkpoint as 1.19.0. Upstream checkpoint history can produce formats older
runtimes reject; cross-version checkpoint portability is not qualified here.
The upstream worker database also changes, independently of SmolBox's store.
In-place upgrades of existing retained machines and rollback of modified worker
state are not established by creating new machines on the candidate. Preserve
worker disks, database, artifact approvals, original keys and ownership records;
follow the [worker upgrade procedure](host-integration.md#upgrading-a-worker).

## Reproduction

Set `SMOLBOX_RUNTIME_VERSION=1.19.0` with dedicated worker/database settings.
Run the ordinary runtime tests and PostgreSQL recovery suite described in
[scripts/ci/README.md](../scripts/ci/README.md). The focused suites additionally
cover `test/checkpoint_runtime`, `test/extended_runtime`, `test/terminal_runtime`,
`test/guest_files_runtime`, `test/workload_runtime`, and `test/ports_runtime`.
Port tests require reachable positive and negative control endpoints.

`test/runtime_compatibility/agent_liveness_test.exs` checks the 1.19.0 guest's
liveness while three low-level streaming commands are active. The client has
four connections per pool; the observation needs the fourth connection. This does not
relax the one-command limit for managed machines. Use only a dedicated worker.

The durable example's `test/release_acceptance_test.exs` runs in separate BEAMs
with `SMOLBOX_RELEASE_PHASE=prepare` and then `resume`, retaining the same store
partition, execution identity, private keys, artifact root and worker. It covers
workload configuration, background launch, terminal access, 16 MiB transfers,
ports, controller recovery, stop/start file persistence and verified deletion.
Linux scripts accept an explicit runtime version and preserve their existing
resource limits. Exhaustion and adversarial probes belong only in the disposable
Linux lab; export receipts before stopping or resetting it.
