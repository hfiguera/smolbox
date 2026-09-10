# Compatibility evidence

Version: `0.1.2` candidate, not released. The library's supported qualification is
`:development`; requested hard-control options remain unsupported. The original
release evidence below records the client/controller contract on Linux and macOS.

## Runtime selection

The candidate adds explicit `runtime_version: "1.14.6"` for Linux x86_64.
The Linux runtime and constrained deployment results are recorded below;
exact-commit release acceptance is recorded separately in the repository's
`docs/release-candidates/` directory.
The default remains `"1.14.1"`, preserving existing configurations. A worker
must report the exact configured version; supporting two versions does not
allow automatic fallback or accepting an arbitrary `1.14.x` release.

SmolVM 1.14.6 on macOS and Linux ARM64 remains unsupported. No new macOS tests
run for this candidate. The older macOS 1.14.1 results below are historical,
not evidence for a different libkrun, runtime or deployment.

SmolVM is installed by the operator, separately from the Elixir dependency.
Use the [upgrade procedure](host-integration.md#upgrading-a-worker) before
changing a worker that owns executions. Keep existing allocation floors until
the selected runtime and approved artifacts have measured replacement values.

The new upstream identity is `v1.14.6`, commit
`6c503014629bba91631152728c3081c944653f31`. The complete Linux x86_64 archive has
SHA-256 `94a1edb0c42b20ac562c3759ed216bab2cab9e27c382f6560969144f7bd1dce3`.
The binary and libkrun identities are recorded with the
[shared storage cleanup comparison](resource-qualification.md#shared-storage-cleanup-retest).
That comparison passed, but does not by itself qualify managed recovery or
the separately enforced Linux deployment.

The [upstream comparison](https://github.com/smol-machines/smolvm/compare/v1.14.1...v1.14.6)
includes changes to disk templates, packing, lifecycle operations and libkrun.
For SmolBox's contract, the relevant changes are:

- Deletion releases VM data before committing registry removal, allowing the
  tested cleanup operation to complete when shared storage is full.
- New disks can be shrunk to the requested size using the host's `resize2fs`.
  In the Linux candidate, a fresh 1/1 GiB request produced two 1,073,741,824-byte
  raw disks and a 1,038,790,656-byte `/workspace` filesystem. This measures one
  artifact/configuration; it does not attest every template or impose a quota.
- Packing changes entrypoint and `USER` handling. Rebuilding a runtime artifact
  requires a new digest and verification of its actual startup and execution
  behavior, rather than reusing approval based on its language tag.
- The default block engine is synchronous. SmolBox does not select or qualify
  the new optional asynchronous engine. Linux seccomp installation and libkrun
  also changed, so old kernel-control results alone do not qualify the new stack.
- Archive path resolution changed upstream. SmolBox's individual bounded file
  operations remain its supported interface; archive and recursive operations
  are not added by this patch.

The eight API paths and nineteen referenced schema components used by the client
were captured from the new binary. Captured lifecycle replies include additional
resource statistics and `blockIo: "sync"`; the client retains its strict required
fields while ignoring additive observations. Buffered output still uses base64
bytes, and streaming retains its lossy UTF-8 contract. This source and wire review
is not a security audit of every upstream change.

### 0.1.2 preparation results

Both Linux worker versions passed all 14 client/runtime cases, 16 PostgreSQL
store cases and 25 durable recovery cases. The 1.14.6 run first used the approved
1.14.1 Python/Node artifacts. A second 14-case runtime run passed with new payloads
prepared by 1.14.6 from those same layers using `pack create --from-vm`, without
network access or a new registry pull. Those payloads have new digests and were
separately approved; they do not establish compatibility for arbitrary images.
The expanded runtime suite also verified buffered bytes, lossy UTF-8 streaming
and explicit guest UID 65534 through both execution modes.

The complete constrained Linux campaign passed with 1.14.6, including all ten
workload probes, eleven startup refusals, actual worker OOM, database failure,
the 300-second worker deadline, and frozen outer-VM recovery. See the
[deployment retest](resource-qualification.md#smolvm-1-14-6-linux-deployment-retest)
and [machine-readable evidence](evidence/smolvm-1.14.6-compatibility.json).

One initial recovery run failed four cases before reaching their intended
interruption boundaries. The failures involved cold preparation and unresolved
cleanup under the worker CPU cap. The examples now allow a 60-second operation
and 55-second receive budget, matching their existing preparation profile; the complete
25-case rerun passed. Command deadlines, leases, retention and uncertainty
semantics are unchanged. The failed attempt remains in the evidence, and a
startup failure can still require external worker teardown.

The default is retained for compatibility with existing worker installations.
For a new Linux x86_64 installation using this candidate, explicitly select
1.14.6 to obtain the tested upstream cleanup fix. Updating the Elixir dependency
does not update a separately installed worker.

A subsequent
[Linux deployment campaign](resource-qualification.md#subsequent-linux-deployment-validation)
verified external worker resource enforcement and failure recovery on one pinned
nested configuration. Those results supplement the earlier platform evidence;
they do not change the library's profile options or establish macOS host limits.
Protected real-worker GitHub infrastructure and independent consumer review were
outside the original release scope and were not added by this campaign.

The 0.1.1 documentation and validation release leaves library source and production
dependencies unchanged from 0.1.0. Its validation is restricted to Linux by the
maintainer: ordinary CI, supported Elixir/OTP lanes, bounded real-runtime suites
and fresh package consumers must pass for its exact commit. The earlier macOS
results remain historical evidence; they are not a new 0.1.1 macOS run. The
repository's `docs/release-candidates/` reports record each release's identity,
validation and scope separately. Excluded work is not represented as completed.

## Current development toolchain

The repository pin and main CI configuration use Elixir **1.20.4 / OTP 29.0.6**.
On September 7, 2026, this pair passed the following checks on macOS Apple Silicon
and Linux x86_64 with KVM. The macOS run used the library and test code at
`de4f35f`; the Linux run used a clean, separate checkout of `a480f8f`. Library,
test, example and dependency-lock contents are identical between those commits.

| Check | macOS arm64 | Linux x86_64 |
|---|---|---|
| Deterministic suite | 186 passed | 186 passed |
| Production-library coverage | 95.40% | 95.40% |
| Dialyzer, Credo, ex_slop, ex_dna, Credence | All passed | All passed |
| Quality canaries | 8 bad/clean pairs passed | 8 bad/clean pairs passed |
| Standalone maintainer tools | 22 passed | 22 passed |
| PostgreSQL store contract | 16 passed, PostgreSQL 17.10 | 16 passed, PostgreSQL 16.15 |
| Real SmolVM client/runtime suite | 14 passed | 14 passed |
| Durable restart recovery | 25 passed | 25 passed |
| Exact getting-started walkthrough | Passed | Passed |
| Host examples | Both compiled and passed forced Dialyzer | Both compiled and passed forced Dialyzer |
| Root and example dependency audits | Passed | Passed |
| ExDoc and local file/fragment links | 42 pages passed | 42 pages passed |
| Fresh package consumers | Current and minimum dependencies passed | Current and minimum dependencies passed |

Each deterministic run contains 4 doctests, 6 properties and 176 ordinary tests;
the 14 real-runtime cases run separately. Both walkthroughs verified duplicate
handle reuse, expected output-file contents and confirmed cleanup. Both package
dependency selections used OTP 29; they do not replace minimum-toolchain testing.

See the [macOS evidence](evidence/otp29-macos.json) and
[Linux evidence](evidence/otp29-linux.json) for source hashes, seeds, runtime
report digests and toolchain identity. No library code changes were needed for
this pair. Each worker used pinned SmolVM 1.14.1 and its previously qualified
native Python/Node artifacts. Dedicated socket-only test databases were stopped
after checking empty execution/identity tables; actual database-outage rejection
passed. Worker inventories were empty and existing services were preserved.

Run Mix checks sequentially within each project. On Linux, an initial example
Dialyzer run lost a consolidated BEAM file while other Mix checks ran in the same
build directory. The same commands passed when run alone, without source or lock
changes; the evidence records both attempts. Serialize dependency audits across
projects too because they share an advisory checkout.

These are development-host results, not a GitHub Actions run or a new
release-candidate attestation. CI retains Elixir 1.18.4/OTP 27.3.4.15, Elixir 1.19.5/OTP 28.5 and
Elixir 1.20.4/OTP 28.5 compatibility lanes. The accepted candidate below retains
its original toolchain and evidence.

OTP 29 reports deprecated `catch` expressions while compiling the maintainer-only
Yamerl dependency, and Credence retains its existing upstream compiler warnings.
SmolBox and both host examples pass their own warning-as-error compilation gates;
dependency warnings are not suppressed or counted as library warnings.

## Accepted RC1 scope (historical)

The library baseline passed 156 deterministic cases (six properties and 150
ordinary tests) on all six host/toolchain combinations listed below. The Elixir
maintainer-tool migration added 22 regression cases; that 178-case suite
passes on canonical macOS and Linux. The standalone tooling tests also pass
on Elixir 1.18.4/OTP 27.3.4.15 on both hosts. Fourteen
real-runtime cases are excluded from that count; all fourteen separately pass
on canonical macOS and Linux. The durable host separately passes 25 real-worker
recovery cases per platform, including fresh controller termination and
dispatcher/notification faults. Three owned worker-service fault scenarios pass
on each host. These are development-host results, not protected GitHub runs.

All five requested analyzers and their deliberate bad/clean canaries pass on both
canonical hosts. Production-library coverage remains 95.40%; maintainer modules
are excluded from that percentage, like the existing developer tasks.
The evidence files below record the earlier library milestones; their source
hashes and test counts are unchanged by the maintainer migration:
[compatibility lanes](evidence/phase8-compatibility.json),
[live output/path boundaries](evidence/phase8-boundaries.json),
[durable telemetry recovery](evidence/phase8-telemetry.json),
[service and CI harness](evidence/phase1-live-ci.json), and
[warm durable workload](evidence/phase8-benchmarks.json), and
[contained Linux resource experiments](evidence/phase8-linux-containment.json), and
[macOS guest-memory overload](evidence/phase8-macos-memory.json), and
[empty versus cached Linux image state](evidence/phase8-cache-state.json).

The sections after “Historical milestone records” retain earlier test counts
and gaps as an audit trail. They do not supersede the candidate summary or the
remaining release requirements.

## Pinned upstream

- SmolVM `v1.14.1`, commit `e8d09ef616d363004d55b80a6cdb31a4e7e1842d`.
- macOS arm64 release archive SHA-256:
  `27f2ae7057f235a67a58fd13d0657c268cf9a16f214f8b177427d29daab0ae2f`.
- Linux x86_64 release archive SHA-256:
  `e91786c12808ce87655aa190eb5f6692672cd659a89367b5ec18dace5756af2f`.
- Exported OpenAPI SHA-256:
  `9ccc9eace040b1b44031f1abf9126496d750e8b2ba5bcaa734e7d62bade67bbe`.

Archives were downloaded from the [upstream release](https://github.com/smol-machines/smolvm/releases/tag/v1.14.1)
and matched the release API digests. Source was inspected through read-only Git
objects because the provided checkout was incomplete during the initial audit.

## Initial host observations

macOS arm64: Darwin 25.6.0; official binary starts and serves health/version.
A prepared Python artifact successfully created, started, and executed a Python
command with `network: false`, no mounts/ports, and restart policy `never`.
This is initial evidence, not the completed platform suite.

Linux x86_64: `ssh linux`, kernel `7.1.5-76070105-generic`, readable/writable KVM,
8 logical CPUs, approximately 64 GiB RAM. Official binary starts and serves
health/version. Both platforms pass the initial Python/Node smoke probe below.

The Linux runtime uses `/tmp/smolbox-qualification/data` as a dedicated data root.
Its login shell initially had no Elixir, Mix, or SmolVM on PATH; the pinned
SmolVM distribution was extracted in `/tmp/smolbox-qualification/runtime`.
Elixir 1.20.4 / OTP 28.5 was installed under `/tmp/smolbox-qualification/mise`
for library tests, without changing the account's global toolchain.
macOS uses unique test machine
names in the normal SmolVM state directory: `SMOLVM_DATA_DIR` is Linux-only in
this release. Never delete machines belonging to another workload.

### Runtime smoke coverage

The original standalone Phase 0 probe has been retired. Its lifecycle, allocation,
binary file/output, nonzero exit, Python/JavaScript streaming, timeout and network
checks are now covered by the maintained Elixir runtime suite. This suite exercises
the actual SmolBox client and remains separate from ordinary `mix ci`.

Prepare approved Python and Node artifacts using the [deployment guide](security.md).
The original Phase 0 artifacts used `python:3.12-alpine` and `node:22-alpine`,
with `/bin/true` as the entrypoint and restart policy `never`. Those image tags
are preparation inputs; each qualification uses the actual artifact digest.
Start the pinned worker with `SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576` on loopback,
then run from the repository root:

```sh
SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470 \
SMOLBOX_PYTHON_ARTIFACT=/absolute/path/to/python.smolmachine \
SMOLBOX_JS_ARTIFACT=/absolute/path/to/node.smolmachine \
MIX_ENV=test mix test test/runtime --include runtime --warnings-as-errors
```

The following reports retain the original Phase 0 observations and tool identity;
they are historical evidence, not results from the replacement runner.

Reports: [macOS](evidence/phase0-macos.json), [Linux](evidence/phase0-linux.json).
Both demonstrate create/start with no mounts, ports, or guest network; binary
file round trips; byte-exact buffered output with a nonzero exit; an observed
one-second command timeout; text SSE and exit; failed public TCP egress; and
stop/delete. Timings include intentional timeout tests, not performance benchmarks.
These probes do not prove child-process termination, connection-loss recovery,
control-plane isolation, hard host quotas, or managed-library behavior.

A separate macOS connection-loss probe opened a ten-second Python command's
SSE stream, read its first output event header, and closed the connection.
The VM still reported `running`; an explicit stop returned `stopped` in about
75 ms. This demonstrates that closing observation is not whole-VM cancellation;
it does not recover the lost command's exit status or establish a latency SLA.

## Source-derived contract findings

These findings require continued real-runtime verification:

- Buffered exec carries `stdoutB64` and `stderrB64`; use those for byte accuracy.
- SSE stdout/stderr contain plain lossy UTF-8 text, not JSON-encoded bytes.
  SSE exit data is JSON with `exitCode`. Never label text streams byte-exact.
- The SSE handler ignores `stdin`; reject supplied stdin on the streaming path.
- Streaming relay has an 11 MiB aggregate cap plus one received frame. The
  channel is unbounded by count, so limits on controller capture do not replace
  upstream/host memory accounting or frame-bound verification.
- File download buffers server-side. Configure `SMOLVM_FILE_TRANSFER_MAX_BYTES`
  on workers; the default 4 GiB is unsuitable for small-file profiles.
- File transfer into image machines invokes an internal `/bin/true` command to
  activate the overlay. This is not the user command and must not become one.
- File GET and PUT also ensure the machine is running. Download is not a purely
  observational operation: it can restart a stopped machine. Reconciliation
  must not use file reads as a harmless liveness probe or collect after confirmed
  termination through this endpoint. Stop/delete must remain the final lifecycle
  operations for a cancelled machine.
- Exec has no verified durable request receipt or deduplication ID. Lost
  acceptance/result evidence remains unknown; never automatically replay exec.
- Machine identity includes `createdAt` at second resolution, not a verified
  immutable generation token. Namespace exclusivity is an operator requirement;
  a matching name alone cannot authorize deletion after a conflict.

## Capability status

| Control | Linux x86_64 | macOS arm64 |
|---|---|---|
| Guest vCPU/memory allocation | Observed configuration; bounded guest OOM experiment passes | Observed configuration; finite guest OOM counter/log experiment passes |
| Host RSS / CPU-time hard quota | Unsupported library controls; the separate deployment tests charged memory and CPU bandwidth, which are different quantities | Unsupported library controls; no corresponding host enforcement tested |
| External worker CPU/memory/task limits | The nested deployment recorded CPU throttling, OOM kill at 1.5 GiB charged memory and task denial under a 96-task cap | Not covered by the Linux campaign |
| Guest disk and host storage accounting | 20/10 GiB floors; earlier shared-storage exhaustion prevented deletion; later separate 768 MiB VM/cache and 64 MiB metadata mounts passed exhaustion and cleanup | Same template floors verified; host quota pending |
| Hostile process count control | Unsupported hard control | Unsupported hard control |
| Deadline and whole-VM termination | Real timeout/cancellation/recovery passes; the nested deployment also passed a 300-second worker deadline and frozen outer-VM recovery | Real timeout/cancellation/recovery passes; the external deadline campaign was Linux-only |
| Output and file transfer caps | Finite overflow/file cap pass; contained blocked-reader probe passes; broader buffering pending | Finite overflow/file cap and blocked callback pass; independent host quota qualification pending |
| No guest egress / control-plane access | Public TCP and three control-plane routes denied; broader isolation pending | Same |
| Durable result recovery | Persisted results survive controller failure; no upstream receipt for a lost result | Same |
| Safe cancellation and cleanup | Unknown outcomes and reservations survive faults through retention and verified cleanup | Same |
| Authenticated TLS proxy | Real worker forwarding passes | Real worker forwarding passes |
| Canonical workspace containment | Unsupported; guest symlink read escapes the lexical workspace | Same |

Unsupported hard-control options are rejected before dispatch. The external
Linux controls above are configured by that deployment, not by a profile field.
They cover one execution at a time and do not qualify concurrent tenants.
Delayed requests remain unfenced on both platforms. See
[resource qualification](resource-qualification.md) and [security](security.md)
for measured scope, independent deadline behavior and remaining limits.

## Toolchain

The table records the six-lane library baseline before the maintainer-tool
migration. The expanded 178-case suite was rerun on both canonical hosts; its
22 standalone tooling cases also pass on both minimum-toolchain hosts. This
does not claim a rerun of the full expanded suite on every earlier lane.

The maintained package, rather than only the original scaffold, passes these
lanes after the bounded deadline-fixture correction:

| Elixir / OTP | macOS arm64 | Linux x86_64 |
|---|---|---|
| 1.18.4 / 27.3.4.15 (minimum) | 156 passed | 156 passed |
| 1.19.5 / 28.5 | 156 passed | 156 passed |
| 1.20.4 / 28.5 (canonical) | 156 passed; all five analyzers | 156 passed; all five analyzers |

Each lane excludes 14 explicitly opt-in real-runtime cases. On Elixir 1.18 the
summary includes those exclusions in its printed “164 tests”; the executed
count is 150 ordinary tests plus six properties. One cold Linux run exposed a
test fixture that assumed a 50 ms request always reached its peer. The corrected
fixture confirms acceptance before measuring bounded outer/idle deadlines and
passes all lanes. No library deadline or transport behavior changed. Seeds,
durations, matching source hashes and the failed attempt are retained in
[compatibility evidence](evidence/phase8-compatibility.json).

Use separate workspaces for simultaneous Elixir/OTP lanes. Sharing dependency
directories can mix rebar build artifacts. Source transfers to Linux must omit
macOS resource-fork/AppleDouble metadata; otherwise `._*.exs` files are invalid
Elixir inputs. The recorded successful Linux run used a plain source archive.

Credence 0.8.1 emits upstream compilation warnings on Elixir 1.20.4; Mix's
dependency compilation reports them separately from the project's warning gate.
They are not suppressed or represented as SmolBox diagnostics. The library and
developer tasks pass warning-as-error compilation. No dependency source was patched.

The source repository is [hfiguera/smolbox](https://github.com/hfiguera/smolbox),
configured as `origin` and in the package and documentation metadata. The repository
is public. ExDoc source links target the matching `v0.1.1` tag. The supplied host
examples and automated package consumers provide first-release adoption evidence;
no independent consumer review is required or claimed.

The first [GitHub CI run](https://github.com/hfiguera/smolbox/actions/runs/34138037540)
at `17fabbaf30281d11303a2980042d7b0f975e43f5` passed all 16 ordinary jobs. Its
aggregate failed under the previous policy because both real-worker jobs were
skipped. That run does not validate the later opt-in policy or metadata change.
Protected runtime qualification has not run and is optional for the first
release; the existing real suites still require exact-candidate local evidence.

## Historical milestone records

The following sections describe earlier increments in order. Counts and pending
items are historical; use the current summary and capability table above for
the latest status. The linked evidence files retain their original contents,
including missing-remote and source-metadata observations made before repository
setup.

## Low-level Elixir client qualification

Five opt-in `ClientRuntimeTest` cases pass on each initial platform using the
same pinned runtime and artifacts from the Phase 0 manifests. They cover Python
binary output/file collection with nonzero exit, JavaScript SSE/file output,
public TCP denial, observed timeout, explicit VM stop during streamed execution,
neutral restart, and authenticated TLS forwarding to the real worker. Each
case creates an opaque name and checks ownership before stop/delete. Both
worker inventories were empty after the suite. These tests do not exercise
managed recovery, store durability, or hostile resource enforcement.

Run on the worker host, where the artifact paths can be checked:

```sh
SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470 \
SMOLBOX_PYTHON_ARTIFACT=/tmp/smolbox-qualification/python.smolmachine \
SMOLBOX_JS_ARTIFACT=/tmp/smolbox-qualification/node.smolmachine \
MIX_ENV=test mix test test/runtime --include runtime --warnings-as-errors
```

Missing required environment or an unavailable worker fails the explicitly
selected suite. Normal `mix ci` excludes runtime-tagged cases and requires no
worker. Its 48 deterministic cases pass on macOS/Linux canonical toolchains,
Elixir 1.18.4/OTP 27.3.4.15, and Elixir 1.19.5/OTP 28.5. All five analyzers pass
on both canonical hosts. Controlled actual HTTP peers test lost connections,
redirect rejection, TLS trust/hostname failures, authentication, Unix sockets,
SSE fragmentation/limits, blocking observers, and no POST replay. Coverage is
98.99% across compiled library and test-support modules.

Source inspection additionally found atomic temporary-file installation in the
agent. Guest-path resolution varies with the active namespace and needs hostile
symlink/race qualification before any stronger containment claim. The HTTP API
has no permission option. See the [client guide](client.md) for current semantics.

## Durable store qualification

The host example passes 10 tests against PostgreSQL 16.15 on Linux x86_64,
including concurrent store conformance, rollback/corruption, and a fresh BEAM
read. A separate probe with the actual database stopped confirms typed failures
for capability inspection, lookup, and acceptance. The database is isolated on a
private Unix socket and was restored afterward. Evidence and package/container
checksums are recorded in `docs/evidence/phase4-durable.json`.

Postgrex 0.22.4 emits an upstream deprecated `xref` exclusion warning with Elixir
1.20.4. Project and example source pass warning-as-error compilation; dependency
source is not patched or diagnostics suppressed. The example has separate locks,
Dialyzer, and vulnerability audits. This database result does not yet demonstrate
controller restart during a real managed execution.

## Initial managed-runtime qualification

The combined real suite now has seven cases on each initial platform. Two new
managed cases execute prepared Python/JavaScript with staged source, nonzero
exit, binary collection and confirmed deletion, and cancel a running guest while
preserving an unknown outcome with confirmed termination. Test-owned retained
machines are removed by an ownership-checked fixture finalizer. Both inventories
are empty afterward. This is not yet full retention-window or crash-boundary
qualification.

The managed increment passes 86 deterministic cases with 94.30% library coverage
on canonical macOS/Linux and all five analyzers on each. The durable example has
12 real Postgres cases, including managed durable startup. See
`docs/evidence/phase5-managed.json` for versions, seeds and source hashes.

## Delayed request and controller-fault evidence

Thirty-five controlled controller-interruption boundaries and two delayed-request
cases now pass on canonical Linux/macOS. The delayed-exec case also passes against
both real workers: an original request held before forwarding can start the VM
after a successful stop. SmolBox sends no second exec; it reobserves and stops the
owned VM again while preserving unknown outcome and its reservation. This
experiment disproves treating a stop response as a fence for pending requests.

A recovered ambiguous create without recorded creation evidence never releases
capacity merely because inspection temporarily returns 404. The old request may
still create a resource. The host integration guide documents the resulting
operator quiescence requirement. Source inspection also found that exec obtains
its in-memory machine reference before the implicit-start lifecycle lock; a lock
alone must not be represented as durable request fencing.

The runtime suite now contains eight cases; this increment reran its three managed
cases on each platform. The five unchanged client cases were last run together
with managed tests in the Phase 5 increment. Full store-backed process termination,
worker restart, retention-window completion and hostile resource qualification
are still pending. See `docs/evidence/phase6-controller-faults.json`.

## Durable process-kill and host-example evidence

Eighteen real PostgreSQL-backed controller SIGKILL boundaries pass on each
platform: Linux seed 271982 (267.5 seconds), macOS seed 791731 (260.2 seconds).
Each case kills an owned child BEAM at a named boundary and recovers through a
fresh BEAM using the original keys, store partition, spec and execution ID.
These are real SmolVM calls and database commits, not mocked restart tests.

The suite covers dispatch intent, first output, result/artifact writes, completion,
stop, delete, absence recording and reservation release. Lost result evidence
stays unknown; persisted results and collected artifacts survive. A trusted host
test ledger verifies no second client dispatch attempt; it is not an upstream
acceptance receipt. Unknown cases wait through the real 60-second example
retention interval before automatic deletion and release. The library's default
retention remains 24 hours. Absence and termination are observations, not fences
for arbitrary pending worker requests.

Both minimal and durable host examples pass normal execution and cancellation on
both platforms. Normal runs verify reversed binary data and a one-byte test
marker; cancellation retains unknown outcome while cleanup completes. They
keep keys in private host files. macOS durable
tests connect to the dedicated Linux PostgreSQL instance over an SSH-forwarded
Unix socket in a private directory; no public database listener was added.

The ordinary durable conformance suite still runs separately: 12 cases on each
host, excluding the 18 explicitly opt-in VM cases. Example Dialyzer now forces
PLT validation because path-dependency changes do not necessarily change the
example lockfile. All five root analyzers and deliberate bad/clean canaries pass
on both canonical hosts. Actual worker-service restart, orphan discovery, host
resource abuse, and release acceptance remain pending. See
`docs/evidence/phase6-durable-recovery.json` for this increment.

## Bounded orphan inspection and assignment indexes

`audit_worker/3` now reports namespace candidates through a bounded, read-only
worker/store comparison. Controlled cases verify ownership evidence, conflicts,
untracked names, cleanup races, pagination, redaction and timed-out stores. A
real untracked candidate remains untouched on both platforms; running managed
VMs are matched to their stored assignments.

Both adapters retain unique worker/name assignments after cleanup. The durable
example's second migration adds the index; existing example partitions were
backfilled using their original keys without changing execution records.
Conformance now has nine shared scenarios plus two PostgreSQL migration tests.
All 15 ordinary Postgres tests pass on each host, and all 18 actual controller
SIGKILL cases were repeated successfully on each platform after the index change.

The canonical suite passes 127 deterministic cases and all five analyzers on
both hosts, with 94.79% library coverage. The real runtime suite has nine cases;
this increment reran all four managed cases on each platform. The five client
cases remain separately recorded historical evidence until the full release
matrix runs again. See `docs/evidence/phase6-orphan-inspection.json`. Worker
service restart and the remaining isolation/release gates are still pending.


## Allocation floor correction (September 7)

The increment after `137ed09` corrects an admission assumption found by real
resource probes. SmolVM 1.14.1 reports requested disk sizes even when it retains
larger runtime templates. On both hosts a 1 GiB storage request exposed
21,118,275,584 guest filesystem bytes. Linux raw disks were 20/10 GiB. See
[resource qualification](resource-qualification.md) for source paths, cgroup
observations, the bounded guest OOM experiment, and remaining requirements.

Workers now require an operator-declared `allocation_floor`. Smaller profiles
fail new submission and recovered prepared dispatch. Examples use immutable
profile v2 with 20/10 GiB disks and 768 MiB VMM overhead; records keep their
original fingerprints and are never rewritten. This corrects configured
reservations without claiming a host filesystem quota or cgroup attestation.

At this increment, `mix ci` passes 144 cases on each canonical host with all five
analyzers. All nine real client/managed cases and all 21 durable real-worker cases
pass on each host. Clean minimum Elixir 1.18.4/OTP 27.3.4.15 and additional
1.19.5/OTP 28.5 lanes pass the same 144 deterministic cases. Bad and clean
compiler/analyzer/coverage canaries pass their expected outcomes on both hosts.
Seeds, durations and source hashes are in
`docs/evidence/phase7-resource-floor.json`. None of this marks hard-profile
certification or release acceptance complete.


## Repeatable production-package consumer check

`elixir scripts/ci.exs package-consumer` builds the actual Hex tarball, bounds and
allowlists its members, extracts it into a private temporary directory, and
creates a fresh `MIX_ENV=prod` consumer. It checks a supplied fake-transport
health response and explicit Memory/SmolBox supervisor startup with no workers.
No worker API is contacted. Both the consumer and extracted SmolBox project
compile with warnings treated as errors. Package source hashes must remain
unchanged, and resolved dependencies/compiled modules must exclude CI and
example-only code. This smoke test does not replace real-worker qualification.

Run under the selected toolchain from the SmolBox repository root:

```sh
elixir scripts/ci.exs package-consumer \
  --report /absolute/new/consumer-current.json \
  --package-output /absolute/new/smolbox.tar
elixir scripts/ci.exs package-consumer --minimum \
  --archive /absolute/new/smolbox.tar \
  --report /absolute/new/consumer-minimum.json
```

Outputs must not already exist. `--archive` accepts an already built **trusted**
SmolBox archive so different hosts/toolchains can test the identical artifact.
Its Mix project executes during compilation; this tool is not a sandbox for
untrusted packages. Temporary consumer files are removed on completion or error.
The report records package/file hashes, toolchain, architecture, runtime versions,
resolved dependency names, consumer lockfile and smoke results. `--package-output`
retains the exact tested archive without publishing it.

The minimum direct versions are Req 0.7.4, Jason 1.4.0, telemetry 1.3.0 and
NimbleOptions 1.1.0. Transitive dependencies are resolved and recorded, not claimed
to cover every permitted combination. Jason 1.4.0 emits upstream deprecation and
optional-Decimal warnings on newer Elixir. No upstream sources are patched or
warnings hidden. SmolBox itself is compiled as the root project with warnings as
errors because a consumer's flag alone does not enforce that on dependencies.

CI runs the current consumer in the docs/package job and a required minimum
consumer on Elixir 1.18.4/OTP 27.3.4.15. Successful reports and tested tarballs use
a pinned upload-artifact action with missing outputs treated as errors. Actionlint
passed locally at that milestone; GitHub execution was not yet available. These
checks advance an independent acceptance item while resource certification and
the final release matrix remain incomplete.

## Telemetry milestone

Bounded, redacted managed telemetry and inspection are documented in the
[telemetry guide](telemetry.md). Both canonical hosts pass 156 deterministic
cases and all five analyzers; library coverage is 95.40%. Nine live cases and
25 durable-host cases pass on each platform. The durable matrix includes fresh
controller termination before/after notification delivery and dispatcher failure
before/after result persistence. Results, one-command markers, binary artifacts,
capacity and cleanup survive those failures. Notifications remain optional and
lossy; stored evidence is authoritative.

A fixture initially tried to reuse the private telemetry ETS handle as user
configuration during restart. Validation rejected it before dispatch. The fixture
now retains its public options, and both full live suites pass. This illustrates
why a deterministic-only pass is insufficient for a supervision change.

The same 70-file package archive passes fresh production consumers on canonical
macOS and minimum direct dependencies on Elixir 1.18.4/OTP 27.3.4.15 on both hosts.
That archive predates this evidence and later documentation changes; it is not
the final release artifact. Source hashes, seeds, counts, archive identity and
limitations are recorded in [telemetry evidence](evidence/phase8-telemetry.json).
