# smolvm 1.16.0 qualification

Status: **in progress**. Branch `support-smolvm-1.16.0` starts from
`b649bdb0f29c574f89caebd20ac8ca3c06495bfa`. The default remains 1.14.6;
the explicit 1.16.0 selection on this branch is a candidate for testing, not
completed platform qualification. No release or public API expansion is planned
in this task. Existing runtime selections and execution semantics remain intact.

## Inputs and source review

The reference checkout was clean when rechecked on September 13, 2026. Its HEAD
is `9d442abd49169f3b2971f877fa687ef5763d9dc7`, two commits after the release.
It was inspected without modification. Testing uses a separate Git archive of
official tag `v1.16.0`, commit `e1dd54bf7be6d144ad6bdef4ebf310f57809a6a6`.
Neither later checkpoint port rebinding nor parallel export compression changes
are attributed to this release.

The official release was published at `2026-09-13T05:22:38Z`. Downloaded platform
archives match both GitHub's release asset digests and `checksums.sha256`:

| Archive | SHA-256 |
|---|---|
| Darwin ARM64 | `7be55af510b698bb95c9e9b103004c81f75cacfaa62b00aaf554441e9023353b` |
| Linux x86_64 | `cb7d6ea34914b4d71958e16eafc8a3220fe9e8cd5b76fa983ef9f648159f4c9b` |

The tag pins libkrun `d1f79154fbfd7e8ecf9d4e259e2006524e6cf913` and libkrunfw
`6ec329e11154814a4df9963a3f94f2a430f55723`. This identifies the source provenance;
binary and behavioral checks are separate. Cargo.lock changes workspace versions
and adds the existing zstd dependency to the main crate; no third-party version
upgrade appears in that lock diff.

Source comparison against 1.14.6 found no changes to `src/api/types.rs`, the exec
handler, or the file handler. Router changes remove the generic 300-second timeout
from start, exec, streamed exec, run and image pull. Bounded lifecycle/file routes
retain it. Real execution through the Elixir transport must still establish
long-command behavior and bounded shorter deadlines.

Machine creation now verifies the prepared artifact footer before reading its
manifest. Existing approved artifacts therefore need live verification. Supervisor
changes forget externally deleted database entries and preserve a live recorded
PID when an in-memory manager lacks its child identity. Memory/scope and restart
changes require renewed process containment and recovery observations.

Nix adds e2fsprogs to runtime dependencies on macOS. This is a packaging change,
not evidence that an archive supplies a host-compatible resize2fs executable.
Nix is reviewed, not an installation path qualified by this campaign.

The Nix expression at the official tag also still contains the old 1.14.6 archive
hashes while selecting 1.16.0 filenames. Decoding its Darwin and Linux x86_64 SRI
values yields `484b63c6a7c74c4d05dce2e63fcce3d135e0fba56a1d77128024e5736d3384a8`
and `94a1edb0c42b20ac562c3759ed216bab2cab9e27c382f6560969144f7bd1dce3`, which do
not match the official 1.16.0 archives above. This source discrepancy is another
reason not to describe the untested Nix path as qualified. Archive testing uses
the verified release assets directly, without changing upstream files.

The official Darwin binary exports the same eight used paths and nineteen
referenced schemas as the captured 1.14.6 subset. The complete OpenAPI hash is
also unchanged: `f3a0cf982a82acc125d1d02d09d707f0467b9867b4e17281d65a461a6b76ef99`.
This does not cover undocumented readiness or actual response behavior.
The libkrun comparison contains retained-RAM checkpoint streaming changes;
libkrunfw enables KVM in the ARM64 guest kernel. Neither new feature is exposed
by this SmolBox change. Their exact archive binaries still receive ordinary
execution checks on the relevant host.

## Initial working-tree checks

The first canonical macOS `mix ci` run passed 204 deterministic cases (seed
8734), compilation, formatting, cycle checks, Credo/ExSlop, ExDNA, Credence and
Dialyzer. The fourteen excluded runtime cases are not counted as passes.
All nine ordinary native macOS runtime cases then passed separately (seed
246468). This run excludes the five security cases reserved for Linux.

The retained 1.14.6-prepared macOS artifacts match the previous release report:
Python `d4fdc417ae000a1b56c99a1e6d8ee216b094f1dbd5ba1bf3c9fb613d404d9120`
and Node `38d8ed81c1e7094494634b354a4a1c591dcd59c1c0a14aabeebc39dda5162d37`.
The older `/tmp/smolbox-qualification` payloads are no longer present; they were
not silently replaced or described as tested.

A separate preparation probe verified the private worker's PATH/HOME, available
e2fsprogs 1.47.4, and two exactly 1,073,741,824-byte raw disks for each artifact.
Binary files survived a complete stop/start cycle and both machines were deleted
with an empty inventory. The worker has a one-hour process-group deadline,
1 MiB captured-log cap and storage guards; these are ordinary-test safeguards,
not hard macOS host resource qualification. Raw results remain in the private
task directory until reviewed evidence is exported. These checks precede the
final candidate freeze.

The initial probe described the private tool on PATH as the supplier. A later
check found a Homebrew installation at `/opt/homebrew/opt/e2fsprogs`, installed
after the prior release's private setup. Tagged source searches that absolute
path first. The effective available host tool is therefore Homebrew 1.47.4,
SHA-256 `2f5c1940c364b2cd451f09f37004c0b7a3eff4a822672acead493f4618e734f0`.
The private PATH wrapper's presence alone does not prove it was invoked; this
correction supersedes that attribution in the retained initial raw report.

A separate owned worker was denied reads of `resize2fs` paths using a process-only
macOS sandbox profile, without modifying the installed tool. A 1/1 GiB request
still started, exposing 20/10 GiB raw disks without formatted markers. After
stopping and restarting it, the previously collected file could no longer be
downloaded. API cleanup succeeded and inventory was empty. This characterizes
missing prerequisites; it is not a successful disk-preparation result. The
initial probe had an overlong test namespace and failed before creation; its
log is retained separately from the corrected experiment. The worker was stopped
and its private process group exited.

The first Linux candidate run passed all fourteen runtime cases (seed 54154,
369.070 seconds) and sixteen PostgreSQL cases (seed 472974). This used commit
`7432953` plus the new runtime selector and exact binary/agent/libkrun preflight
pins. All archive component checks passed, and Linux exports the same OpenAPI
hash as macOS. During the suites, 600 samples observed 801 live account-owned
processes, all within `/system.slice/smolbox-qualification.service`. The service
remains unprivileged with 1.5 GiB charged memory, zero swap and 96 tasks. This is
sampled containment evidence, not completed exhaustion or durable qualification.

Synthetic Linux lifecycle, health, buffered-byte and SSE responses were captured
and added under `test/fixtures/wire/1.16.0/`. The mechanically extracted OpenAPI
subset is byte-identical to 1.14.6. Capture finished with verified deletion and
an empty inventory. A separate Linux geometry probe requested 1/1 GiB and observed
two 1,073,741,824-byte disks with a 1,038,790,656-byte workspace filesystem; its
file survived a complete stop/start cycle and cleanup was verified.

The candidate process's actual PATH includes `/usr/sbin`. Its mount namespace
can execute `/usr/sbin/resize2fs`, supplied by Ubuntu's
`e2fsprogs 1.47.0-2.4~exp1ubuntu4.1`, executable SHA-256
`1a0ea5f6784285b82098fe7935c95bf1ac76713aec904cc9b43920fa85ebe35d`.
The `-V` probe prints the 1.47.0 banner and exits with an invalid-option message;
the successful geometry and persistence run supplies the functional evidence.
The controlled Linux missing-prerequisite case was still outstanding at this
initial checkpoint; its later result is recorded below. Guest reports were
exported before stopping the outer VM; its recovery completed. The descriptor
check used the baseline account, not the candidate account; the independent
candidate stop checks provide the account-process teardown evidence instead.

The initial durable run finished with 23 of 25 cases passing (seed 162868,
1,078.035 seconds). The artifact-directory outage and dispatcher-death-after-commit
cases did not reach their intended boundary within the fixture's 30-second wait;
their retained SQL records were still `preparing`. The original log and failed
runner report are preserved. The worker subsequently reached its independent
300-second lifetime. The suite launcher now stops the candidate on failure too.

The three in-process fault scenarios now use the existing lab-only 90-second
observation allowance, while ordinary runs retain 30 seconds. Production command,
lease, preparation and cleanup budgets are unchanged. All five affected cases
passed in a targeted rerun with the same seed (156.8 seconds), including the two
original failures. That run deliberately excluded the other twenty cases; the
full-suite report validator correctly rejected its result. Its trace is retained
as targeted evidence only; the later complete 25-case rerun is recorded below.

Dependency retirement and vulnerability audits passed. Fresh package consumers
passed with both current and exact minimum runtime dependency versions on the
canonical macOS toolchain. These initial consumers verify the unchanged 1.14.6
default; they do not replace final-candidate package validation.

All eight analyzer canary pairs passed. The first coverage run reached 95.41%
but failed a maintainer test, so the gate did not pass: macOS `lsof` took about
30 seconds and its 30-second sleep fixture expired before mapping collection.
A separate 120-second fixture preserved its executable identity; numeric UID
output did not remove the delay. The test fixture now lives up to 120 seconds
under its own bounded child supervisor, and cleanup still stops it. Executable
identity checks are unchanged. The corrected fixture suite passed with the same
seed, and the full coverage rerun passed all 204 cases (seed 921400) at 95.41%.
ExDoc built without warnings and all 42 pages passed local link/fragment checks.

At `b65709f`, native macOS backward compatibility passed all nine ordinary cases
on 1.14.6 (seed 393358, 20.8 seconds) and 1.14.1 (seed 763237, 28.1 seconds),
using the approved artifacts listed above. Both inventories were empty and both
owned worker groups were stopped afterward. A first 1.14.6 attempt failed during
worker setup because the private Bash wrapper expanded an empty array under
`set -u`; the corrected wrapper and successful rerun are recorded separately.
This was not an upstream runtime failure. Linux backward compatibility remains
pending, as does final-candidate validation on both platforms.

The additional native macOS language lanes passed compilation, 204 deterministic
cases and 23 CI-tooling cases each: Elixir 1.18.4/OTP 27.3.4.15 (test seed 323218),
Elixir 1.19.5/OTP 28.5 (539593), and Elixir 1.20.4/OTP 28.5 (533539).
Runtime exclusions are not counted as passes. These runs used the existing
fixture coverage; the subsequent addition of captured 1.16.0 responses passed
all nineteen affected parser/client cases separately on the canonical toolchain
(seed 430891). Formatting, ExDoc generation and all 42 documentation page link
checks passed after that addition. Final committed-candidate checks remain open.

At `ab7ad95`, native macOS passed nine ordinary runtime cases (seed 623036),
sixteen PostgreSQL store cases (712859), and all twenty-five durable recovery
cases (243606, 276.129 seconds). The database was a private PostgreSQL 17 cluster
listening only on a private Unix socket. The ordinary worker and database were
stopped after the suite; separate service recovery checks use the same owned
installation. Canonical `mix ci` passed 204 deterministic cases and all analyzers
(seed 782338); coverage passed 204 cases (501256) at 95.41%.

A fresh Linux suite at that commit passed thirteen of fourteen runtime cases.
Managed cancellation failed while waiting for `running` (seed 556040,
408.957 seconds overall). Its polling helper still allowed only thirty seconds,
despite the sixty-second preparation/transport configuration. It now uses the
existing lab-only ninety-second observation allowance and reports the last state
if that observation expires. Production deadlines and ordinary platform waits
are unchanged. The isolated cancellation rerun passed (26.754 seconds) with the
same seed; that single case does not replace a full suite. The failed run's
worker journal also recorded a missing-PID stop warning while a VM was reachable;
external service teardown completed. Both the failed report and journal are
retained for comparison with the complete rerun.

At `6a4a6b6`, the complete Linux runtime suite passed fourteen cases (seed
453229, 420.645 seconds), followed by sixteen PostgreSQL store cases (980339).
The accompanying durable attempt failed; the later complete rerun is recorded
below. The failed attempts have not been overwritten by these results.

The [partial macOS evidence](evidence/smolvm-1.16.0-macos.json) now records all
three service recovery scenarios: server restart, extended unavailability, and
external deletion. Each passed with one recorded dispatch and verified cleanup.
A separate process observation retained the same VMM PID and start time through
three API restarts and repeated `start` calls. Each observation contained exactly
one API process and one VMM. Deleting that VM through the CLI while the API was
down left an empty inventory after API restart and no remaining runtime process
after teardown. This is a bounded observation of those specific restart paths.

Short deadline probes returned exit 124 after 1,018 ms buffered and 1,005 ms
streamed for a one-second command limit. A 200 ms receive budget (inside a
250 ms operation budget) returned transport uncertainty after 202 ms; a later
marker proved that the command continued without replay. An expired one-millisecond
managed await did not request cancellation: the original execution completed with
exit zero, one marker byte, collected output and verified cleanup. These cases
do not satisfy the separate execution-longer-than-five-minutes requirement.
An initial probe failed artifact-store setup because its private directory lacked
mode 0700; the corrected attempt is recorded separately. The first successful
restart probe lost its detailed report to a runner filename collision; a clean
rerun retained both the process detail and runner result.

A fresh consumer on Elixir 1.18.4/OTP 27.3.4.15 passed with exact minimum runtime
dependencies and explicit 1.16.0 configuration. Its fixture now exercises that
selection in addition to the unchanged default and legacy selection. This
initial archive precedes the addition of the partial macOS evidence file, so it
is not the final package manifest.

### Further Linux and macOS observations

At `6a4a6b6055d9c28c21c5bea01c7b1ab970f2ee5d`, the complete Linux runtime suite
passed all fourteen cases (420.645 seconds, seed 453229), followed by all sixteen
PostgreSQL store cases (3.505 seconds, seed 980339). The subsequent durable suite
did **not** pass: controllers failed to reach `first_output_record:after` and
`dispatch_intent:before`, and the outer test runner stopped the suite at its
1,200-second deadline. No complete passing test count is claimed for that run.
The worker journal reported a VM still reachable after an attempted scope kill
with no PID to signal. The root cause remains under investigation; increasing
an observation timeout alone would not establish successful recovery.

After external worker teardown verified absence of candidate account processes, the
database still contained three records needing work and three reserved slots.
Those observations establish physical teardown, not completed durable cleanup.
The failed reports, journal and sanitized final resource/store counts were
exported before disposing of the guest.

A separate Linux missing-prerequisite probe completed in 41.543 seconds. With
`resize2fs` temporarily unavailable inside the disposable guest, a requested
1/1 GiB machine started with 20/10 GiB raw disks and no formatted markers. The
previously uploaded file could not be downloaded after stop/start. The guest
existence command ran successfully, but its custom Inspect output omitted stdout;
that report does not independently prove the file was absent inside the guest.
API cleanup verified empty inventory, and the exact original host tool checksum
was restored. Together with the macOS observation, this confirms that consumers
must verify the actual worker's resizing prerequisite rather than infer successful
preparation from an accepted start response.

The fresh Linux durable rerun subsequently passed all 25 cases with the original
seed 1167, in 1,352.806 seconds. Its source was `adc0c27` plus the diagnostic-only
controller change committed as `cd97ecf`; the executed controller file matched
SHA-256 `0b9c7e7eda199b4d9873bb577ea8d8cba793623ad509afb08b0dbe83251ebec8`.
The complete-suite observation budget was 30 minutes, while each controller's
100-second observation deadline and all preparation, execution, lease and cleanup
budgets stayed unchanged. The run included all original interruption boundaries;
no cases were skipped or excluded. Final observation found zero pending database
records and zero reserved slots; external teardown verified absence of candidate
account processes. The descriptor check used the wrong account and supplies no
additional proof for this run. The earlier failed run
remains evidence: this successful rerun does not establish why both earlier
boundary waits failed or guarantee a startup latency under every host load.

During that rerun, 600 additional samples captured 759 live process observations,
all inside the candidate cgroup. This is sampled containment evidence, not an
atomic guarantee about every process lifetime. An initial attempt to launch this
diagnostic suite omitted the required artifact digest and failed fixture setup
before executing any guest commands; its report is retained separately.

The 1.16.0 shared-storage cleanup regression then passed in 24.374 seconds. Guest
writes filled the 512 MiB shared registry/data filesystem to zero available bytes;
stop left only 4 KiB free. API deletion succeeded, reclaimed more than 511 MiB,
and removed the VM data directory. Absence survived an API server restart, and a
replacement machine completed creation, upload, execution, collection and deletion.
Final external teardown verified absence of the cleanup account's processes.
Its descriptor check also used the baseline account and is not independent
cleanup evidence. This focused experiment
used its separate 2 GiB / 200% CPU / 128-task profile with VM UID dropping disabled;
it does not replace the stricter deployment's resource and isolation campaign.
The version-selecting experiment controller is committed as `067b6ec`.

The stricter candidate's external CPU, task and memory boundary probes also
passed inside the disposable guest. The CPU counters recorded 80 throttled
periods; the task controller recorded four limit events; memory exhaustion
recorded one OOM kill and the unit result `oom-kill`. Each probe verified removal
of the owned processes. All eleven negative startup cases were rejected, covering
weakened limits and lifecycle policy, disabled Landlock/private networking,
modified artifacts and a missing storage boundary. Restoring the expected
configuration produced a healthy 1.16.0 worker. These deliberate injections test
the external worker controls separately from guest behavior.

The ten guest workload probes and an additional geometry/persistence probe then
all passed. They covered Python, Node, guest memory exhaustion, CPU saturation,
process creation, full storage, output limits, a slow reader, isolation and file
boundaries. Each verified API cleanup and subsequent external teardown with no
candidate account processes remaining. The baseline account's empty descriptor
report does not add evidence for the candidate account. The VMM's observed threads retained seccomp,
NoNewPrivileges and zero effective capabilities in the candidate cgroup.

These observations preserve the existing limits of the claim: 192 guest children
were allowed, so the host task limit is not a per-guest PID limit. Guest symlinks
can reference other guest paths; the file API does not promise a workspace-only
boundary. The output probes used bounded producers and do not establish behavior
for every possible output stream. Independent durable service-failure and outer
VM recovery evidence is recorded separately below.

### Service fixture failure and descriptor-check correction

A standalone Linux API restart fixture failed after 34.647 seconds and reported
an additional cleanup error. Its original report retained only `ArgumentError`,
so the failure's exact cause is unknown. A fresh diagnostic rerun passed in
92.041 seconds with one dispatch and a surviving guest across the API outage.
Its execution result remained `unknown` with confirmed termination and complete
cleanup; this does not establish a known command exit or successful collection.

An account-specific descriptor inspection then found a detached VMM from the
first failed fixture: PID 26250, UID 1000 (`lab`), started at 00:14:10 UTC on
September 14. At 00:21:04 it still held a KVM VM and vCPU descriptor. The previous
helper inspected `smolbox-worker`, while candidate, shared-storage and standalone
fixtures used `smolbox-qual`, `smolbox-cleanup` and `lab`, respectively. Empty
reports for the baseline account were incorrectly treated as broader evidence.
The helper now accepts those explicit accounts; it detected this live VMM.
Selecting processes only by `smolvm-bin` command name also misses VMM processes
whose command name is `libkrun VM`.

Candidate and shared-storage controllers independently wait for all processes
owned by their actual account to disappear. Those teardown checks remain valid.
The standalone fixture had no equivalent final boundary, so its failed cleanup
must remain a failure. The entire disposable outer guest was stopped at 00:21:12
UTC. Subsequent host observation confirmed `MainPID=0`, inactive state, successful
unit result and completed recovery. This removed the test environment containing
the orphan; it does not retroactively make the fixture cleanup pass.

The fixture now records a fixed, sanitized failure reason and expected phase,
and retains its bounded controller log privately with mode `0600` after failure.
Its initial running-phase observation is aligned with the example's permitted
60-second preparation budget by allowing 90 seconds. This does not explain the
earlier failure by itself.

A fresh guest then ran all three standalone service scenarios inside an external
systemd unit with a 900-second lifetime and control-group teardown. Two initial
setup attempts failed before dispatch because the fresh database lacked the
example's schema; the retained log and PostgreSQL log identified the missing
relation. After applying the existing migrations, all three cases passed:
restart in 90.679 seconds, extended unavailability in 136.702 seconds, and external
deletion in 16.878 seconds. Each recorded one dispatch, an unknown command result,
confirmed termination, complete cleanup and released capacity. Correct account
checks found no KVM descriptors after each case, before the enclosing unit ended.
The unit then exited successfully with no remaining main process.

These runs used source `adc0c27` plus the diagnostic fixture (SHA-256
`b079cc096e3cb1068bf2358cba05a71a5bff4581b14942b67c27a95ca7cc7fca`)
and corrected descriptor helper. Local canonical CI passed all 204 deterministic
tests (seed 110013), all analyzers, 23 tooling cases, and documentation generation
and link checks after these fixture changes. This is checkpoint evidence, not
the final candidate validation.

A separate Linux process-identity probe passed in 20.248 seconds. Three API
restarts retained VMM PID 6866 and its original start time, with exactly one API
process and one VMM at each observation. A new command returned `42` after every
restart, and the original marker remained one byte. CLI deletion while the API
was stopped removed the VM; the next API startup reconciled the stale inventory.
No descriptors remained under the actual worker account after fixture cleanup.
The initial probe failed because unprivileged executable-link inspection omitted
the VMM. The corrected probe used a guarded root inspector matching only the
owned runtime executable inside the disposable guest. Both reports are retained;
this is a bounded observation of those restart paths, not proof against every
possible duplicate-launch race.

The strict deployment's durable worker-OOM and database-outage cases passed in
38.088 and 37.517 seconds, respectively. Both preserved identity and one dispatch,
retained the reservation during the outage, recovered an unknown result, and
released capacity after verified cleanup.

The first independent-deadline fixture returned a passing report after 304.238
seconds, but an additional observation found no KVM descriptors while the API
unit was still active before its deadline. That result proves unit expiry and
durable recovery, not that expiry terminated a still-running guest command. Its
60-second total HTTP budget allowed earlier transport uncertainty and cleanup.
The report is retained with that limitation. The corrected fixture explicitly
allows a bounded 300-second client operation and receive wait, within existing
public limits, and requires live VMM observations during the final 30 seconds of
the unit's actual five-minute lifetime. Production defaults and validation bounds
remain unchanged.

The corrected test passed in 304.920 seconds. It captured 24 observations of VMM
PID 17910, each passing the cgroup/thread boundary checks, during the unit's final
30 seconds. The last sample was approximately 0.3 seconds before the configured
deadline. The observer then confirmed the unit result `timeout`. Durable recovery
preserved identity and one dispatch, retained an unknown result, and released
capacity after verified absence. Final actual-account descriptor checks were
empty. This establishes the recorded deadline scenario; the earlier weaker test
remains separately identified.

Independent outer-VM recovery also passed. The host stopped the frozen baseline
guest at its configured 30-second probe deadline, removed its process and cgroup,
closed the management port, and automatically rebuilt the disposable disk. The
baseline checksum stayed unchanged and the guest marker was absent afterward.
The frozen guest contained no candidate execution; this specifically tests the
outer supervisor independently of smolvm. In the clean replacement, the verified
official 1.16.0 archive was explicitly installed and selected. Its inventory was
empty, a fresh Python execution and API cleanup passed (24.157-second runner),
and external teardown verified absence of the candidate account's processes.

At `adc0c27c8465d7c500bf5ef1b9466112b70009a1`, ordinary native Linux checks passed:
204 deterministic cases (seed 146040), 95.41% coverage, all eight bad/clean analyzer
canary pairs, all 23 CI tooling cases, dependency security checks, both examples'
compilation/cycle/Dialyzer checks, and ExDoc generation/link checks. The fourteen
excluded runtime cases in the deterministic run are not counted as passes there.
These checks ran in a separate temporary host checkout with two BEAM schedulers;
they did not run resource-exhaustion workloads on the physical host.

The three additional native Linux language lanes passed at that same commit:
Elixir 1.18.4/OTP 27.3.4.15 (seed 585175), Elixir 1.19.5/OTP 28.5 (seed 240190),
and Elixir 1.20.4/OTP 28.5 (seed 578120). Each executed 204 deterministic cases
and all 23 tooling cases, with runtime exclusions counted separately. Actual
installed `OTP_VERSION` files were checked. The Elixir 1.20.4/OTP 28 dependency
build emitted Credence compiler warnings; SmolBox's own compilation with warnings
treated as errors passed.

Fresh native Linux package consumers passed with current dependencies and with
the exact minimum direct dependency set on Elixir 1.18.4/OTP 27.3.4.15. Their smoke
checks confirmed explicit 1.16.0 selection, default 1.14.6 and legacy 1.14.1.
The first matrix wrapper called a nonexistent package task; its failed attempt
was retained, and the corrected package command ran separately without repeating
the completed language lanes. These archives precede the final documentation
and default decision; they are not final release artifacts.

Additional bounded macOS checks at the same commit passed both examples' normal
execution and cancellation paths, plus the executable getting-started walkthrough.
A follow-up restart probe retained the same VMM PID and birth identity through
three API server restarts, successfully executed a new command after each restart,
and retained the original one-byte dispatch marker. External CLI deletion while
the server was down was reconciled on restart, with no remaining owned processes.

### Legacy Linux and package checkpoints

At `5abc003`, the fresh Linux 1.14.1 compatibility campaign passed all fourteen
runtime cases (174.198 seconds, seed 383893) and all twenty-five durable recovery
cases (595.131 seconds, seed 63332). Tracked source remained unchanged during
the run. Final checks found zero pending records, zero reserved slots and no KVM
descriptors for the actual `smolbox-qual` account.

The first 1.14.6 campaign at that same source passed all fourteen runtime cases
(427.792 seconds, seed 611407), then passed 23 of 25 durable cases (1412.273
seconds, seed 602028). Both failures happened before the requested fault boundary:
stored error histories show a transport error during create approximately 55.2
seconds after acceptance, matching the fixture's receive budget. Neither creation
had been recorded as verified, and both reservations remained held. Final SQL
counts were two pending records and two reserved slots; stopping the owned worker
left no KVM descriptors for its actual account. These are retained failures,
not a completed compatibility result. The disposable guest was stopped after
exporting the reports and sanitized record histories, without exporting keys.

The follow-up durable fixture uses 120 seconds for preparation and 115 seconds
for receive, within the existing public configuration bounds. Its test observer
allows 180 seconds to reach a boundary. The ordinary example's 60/55-second
defaults, guest command deadline, collection and cleanup budgets, worker resource
limits and 300-second independent worker lifetime are unchanged. With exactly
those two cases selected, both passed (78.986 seconds, seed 602028), with zero
pending records, zero reservations and no KVM descriptors after worker stop.
The tested fixture files are committed in `cfbe8ca`. The subsequent full campaign
against that commit reached its 35-minute harness deadline without completing.
Its retained output contains nineteen completed case lines, four reported
failures, one interrupted case and five cases that had not started. There is no
final ExUnit summary, so it is not a passing compatibility suite.

The four failures occurred before `notification:before`, `artifact_record:after`,
`release:after` and `dispatch_intent:after`. Their diagnostics retained
`not_dispatched` evidence and upstream start/delete protocol errors. The worker
journal also reports VMs reachable over vsock without a PID to signal. Three
records and reservations remained pending. These observations differ from the
earlier 55-second create receive failures; increasing the suite deadline alone
would not resolve them. Their cause remains under investigation.

After the harness ended, the remaining owned controller process group was
identified and terminated. The worker was inactive and actual-account KVM
descriptor checks were empty for both `smolbox-qual` and `lab`. Reports and
sanitized retained-record histories were exported before disposing the guest.
The raw archive SHA-256 is
`6588115599b7a43f0e066c54d5053fd5ee73bacddeaf2bb77b562b909c0e476d`.
This preserves the failed attempt; neither teardown nor the earlier two-case
pass establishes the outstanding full backward compatibility result.

An earlier attempt combined broad runtime inclusion with the name filters and
therefore admitted unrelated cases. It was deliberately stopped and its output
retained as incomplete. The process exited zero after SIGTERM, but there was no
final ExUnit summary; this is not a passing suite. The corrected selection omits
the broad inclusion and requires exactly two passes and 23 exclusions.

At documentation checkpoint `1ac5ff4`, the same newly built package archive
passed current and exact-minimum dependency consumers on native macOS. The
current consumer used Elixir 1.20.4/OTP 29; the minimum consumer used Elixir
1.18.4/OTP 27, with Jason 1.4.0, NimbleOptions 1.1.0, Req 0.7.4 and telemetry
1.3.0. Both confirmed explicit 1.16.0 and 1.14.1 selections, the unchanged 1.14.6
default, and ordinary supervision. The archive SHA-256 is
`56a145eaadfbc9ee48d7f88e8604c0be7fd8148c2b05ab2eaae8401aaa05b149`.
These consumers test package contents and configuration without a real worker;
they are not additional runtime tests or the final candidate archive.

### Committed quality checkpoint and CI cleanup correction

At `bc1a755`, native macOS passed all 204 deterministic cases, 95.52% coverage,
the eight bad/clean analyzer canary pairs, all 23 tooling cases, root and example
dependency security checks, example compilation/cycle/Dialyzer checks, and all
42 documentation pages' local links. Fresh current and minimum dependency
consumers passed against the same archive, SHA-256
`929436886c4e832f26a10b92753bcd461652088e79c7f020fb9727764621b400`.
These were ordinary quality checks with the default still at 1.14.6; they did not
execute an additional real worker or qualify longer guest commands.

The Linux quality run at that commit passed its canonical checks, analyzer
canaries and coverage, then failed one of the 23 CI tooling cases. A killed
process closed its port between the CI supervisor's `Port.info/1` check and
`Port.close/1`, crashing the leader/descendant cleanup test. The original failure
is retained. Commit `0548717` makes closing the owned port tolerate an already
closed port, allowing cleanup reporting to finish. All 23 tooling cases passed
on Linux with the original seed 122257 and another seed 48192, using an isolated
source snapshot with that exact fixed file; macOS also passed all 23 with seed
122257. Formatting, strict analyzers, Dialyzer and all eight canary pairs passed
with the correction. This fixes development tooling, not the public execution
contract. The complete corrected quality run subsequently passed on both Linux
and macOS at `4e5692f`: 204 deterministic cases, 95.41% coverage, all eight
bad/clean analyzer pairs, all 23 tooling cases, root and example dependency
security checks, example compilation/cycle/Dialyzer checks, and all 42
documentation pages' local links. Each of the eighteen gate reports was checked
against its captured output digest and relevant result assertions. Runtime
exclusions were not counted as passes. This checkpoint includes the bounded
preparation fixture correction; final package consumers and default selection
remain separate acceptance work.

### HTTP operation duration and remaining streaming qualification

The existing command maximum is 300 seconds and the managed execution budget
maximum is 300,000 ms. A guest command allowed to run longer than five minutes
cannot be expressed through the existing public contract. A low-level exec
operation can also include implicit startup before the guest command begins;
that total request duration is distinct from the command's allowed runtime.
The original goal asks for qualification under that existing contract. This
checklist previously described commands exceeding five minutes, which would
require a different contract. The HTTP operation boundary can instead be tested
through public `Client.exec/4`, including its real implicit startup. No public
validation bounds or defaults have been relaxed.

At `4e5692f`, buffered execution through the default production transport completed
in **357.460 seconds**. Python measured **299.002 seconds** inside the guest, with
a 300-second command deadline, exit code zero and the expected two-byte marker.
Creation took 770 ms and was outside the recorded exec duration. The client used
a 480-second receive budget and 540-second total operation budget. The enclosing
ordinary-test worker had a separate 1200-second lifetime. This traverses the
former five-minute HTTP boundary without claiming a guest command or managed
execution budget longer than five minutes.

The first attempt used a 360-second receive budget and returned an uncertain
transport error; it did not establish a passing execution. Its report is retained.
The larger bounded budget was used with a fresh machine identity, without
replaying that command. After the successful buffered case, streamed execution
failed after 55.419 seconds with a protocol error. The worker reported that image
workload preparation after implicit startup timed out waiting for an agent
response. No successful streaming command was observed in that attempt. Both
machines completed the fixture's identity-checked API stop/delete/absence steps;
after worker teardown, actual-account KVM descriptor checks were empty. The
overall run remains failed, with the buffered proof recorded separately.

The tagged buffered handler awaits guest execution before returning its response.
The streaming handler instead starts an asynchronous execution task and returns
an SSE response after VM startup and request setup. Its response body continues
to deliver events while the command runs. Source review therefore does not support
treating the former HTTP response timeout as an identical command deadline for
both paths. Actual client operation duration, guest duration and stream event
timing must be recorded separately when testing the five-minute boundary.

## Required evidence

- [x] Create the requested branch; preserve the external checkout.
- [x] Resolve the exact release and verify both downloaded archive checksums.
- [x] Finish bundled component and full used-API comparison; capture real wire fixtures.
- [x] Validate explicit version admission and rejection without changing the default.
- [x] Initial Linux x86_64 ordinary runtime suite, approved Python/Node artifacts and cleanup.
- [x] Initial native macOS ordinary runtime suite, approved Python/Node artifacts and cleanup.
- [x] Actual worker resize2fs environment, disk geometry, missing prerequisite behavior
  and file persistence across stop/start on both platforms.
- [x] Buffered public exec operation exceeding the former five-minute HTTP limit,
  with guest and request durations recorded separately within existing limits.
- [ ] Complete the corresponding streaming operation and event-timing check;
  retain its startup failure rather than treating the buffered proof as both paths.
- [x] Shorter command/transport deadlines, await expiry and confirmed cancellation.
- [x] PostgreSQL store contract, durable recovery, database outage, worker failures,
  external deletion reconciliation and duplicate VMM launch prevention.
- [x] Complete contained Linux resource/isolation campaign, effective cgroups and
  independent worker/outer-VM recovery. No exhaustion or adversarial tests on Mac.
- [ ] Real backward compatibility for 1.14.1 and 1.14.6 on supported platforms.
- [ ] Every ordinary CI gate, all analyzers and canaries, language lanes, example
  checks, documentation, minimum dependencies and fresh package consumers.
- [ ] Final support/default decision and synchronized public documentation.
- [ ] Final committed candidate validation, evidence identities and owned cleanup.

Raw preparation material is retained under ignored `.local/qualification-1.16.0/`.
Reports must distinguish source review, tests, failures and corrections. No
earlier runtime result or skipped case satisfies this checklist. Qualification
will apply only to the recorded configurations, not general security certification.
