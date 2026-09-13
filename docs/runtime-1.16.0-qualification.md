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

All eight analyzer canary pairs passed. The first coverage run reached 95.41%
but failed a maintainer test, so the gate did not pass: macOS `lsof` took about
30 seconds and its 30-second sleep fixture expired before mapping collection.
A separate 120-second fixture preserved its executable identity; numeric UID
output did not remove the delay. The test fixture now lives up to 120 seconds
under its own bounded child supervisor, and cleanup still stops it. Executable
identity checks are unchanged. The corrected fixture suite passed with the same
seed, and the full coverage rerun passed all 204 cases (seed 921400) at 95.41%.
ExDoc built without warnings and all 42 pages passed local link/fragment checks.

### Timeout scope conflict

The existing command maximum is 300 seconds and the managed execution budget
maximum is 300,000 ms. A real execution lasting longer than five minutes cannot
be expressed through the existing public contract. The maintainer has been asked
whether to authorize extending only those maxima to fifteen minutes, with defaults
unchanged, or retain the limits and restrict the longer test to upstream behavior.
No validation bounds have been relaxed while that scope decision is pending.

## Required evidence

- [x] Create the requested branch; preserve the external checkout.
- [x] Resolve the exact release and verify both downloaded archive checksums.
- [ ] Finish bundled component and full used-API comparison; capture real wire fixtures.
- [x] Validate explicit version admission and rejection without changing the default.
- [ ] Linux x86_64 ordinary runtime suite, approved Python/Node artifacts and cleanup.
- [x] Initial native macOS ordinary runtime suite, approved Python/Node artifacts and cleanup.
- [ ] Actual worker resize2fs environment, disk geometry, missing prerequisite behavior
  and file persistence across stop/start on both platforms.
- [ ] Buffered and streamed commands exceeding five minutes through SmolBox;
  shorter command/transport deadlines, await expiry and confirmed cancellation.
- [ ] PostgreSQL store contract, durable recovery, database outage, worker failures,
  external deletion reconciliation and duplicate VMM launch prevention.
- [ ] Complete contained Linux resource/isolation campaign, effective cgroups and
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
