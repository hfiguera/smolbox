# Compatibility evidence

Status: qualification in progress, 2026-09-06. No production profile is certified.

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

### Reproducible initial smoke probe

The maintained `scripts/qualify_runtime.py` explicitly contacts a loopback
worker. It is separate from `mix ci`. Use the pinned distribution to prepare
Python and Node artifacts on each matching host, then start `smolvm serve start
-l 127.0.0.1:19470` with `SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576`.
Preparation may fetch approved public images; execution itself uses no guest
network. Initial artifacts were built from `python:3.12-alpine` and
`node:22-alpine`, overriding the entrypoint to `/bin/true` with restart `never`.
Those tags are preparation inputs only; each probe records the actual artifact
SHA-256. Rebuilt artifacts require new evidence.

```sh
python3 scripts/qualify_runtime.py \
  --python /tmp/smolbox-qualification/python.smolmachine \
  --node /tmp/smolbox-qualification/node.smolmachine \
  --report /tmp/smolbox-qualification/smoke.json
```

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

## Qualification still required

| Control | Linux x86_64 | macOS arm64 |
|---|---|---|
| Guest vCPU/memory allocation | Initial allocation only | Initial allocation only |
| Host RSS / CPU-time hard quota | Uncertified | Uncertified |
| Guest disk and host storage accounting | Pending | Pending |
| Hostile process count control | Uncertified | Uncertified |
| Deadline and whole-VM termination | Pending | Pending |
| Output and file transfer caps | Source evidence; binary round trip passes | Source evidence; binary round trip passes |
| No guest egress / control-plane access | Public TCP denial passes; broader checks pending | Public TCP denial passes; broader checks pending |
| Durable result recovery | No verified receipt | No verified receipt |
| Safe cancellation and cleanup | Normal stop/delete passes; races pending | Normal stop/delete passes; races pending |
| Authenticated TLS proxy | Real worker forwarding passes | Real worker forwarding passes |

Uncertified hard controls must be rejected before dispatch. Local development
qualification must not be advertised as production multi-tenant certification.

## Toolchain

Canonical: Elixir 1.20.4 / OTP 28.5. Minimum lane: Elixir 1.18.4 / OTP 27.3.4.15.
Additional lane: Elixir 1.19.5 / OTP 28.5. Scaffold compilation/tests pass on
all three combinations in separate local workspaces. The canonical `mix ci`
also passes on the Linux host. These results cover the scaffold, not the future
managed runtime. Repository pins do not change the user's global toolchain.

Use separate workspaces for simultaneous Elixir/OTP lanes. Sharing dependency
directories can mix rebar build artifacts. Source transfers to Linux must omit
macOS resource-fork/AppleDouble metadata; otherwise `._*.exs` files are invalid
Elixir inputs. The recorded successful Linux run used a plain source archive.

Credence 0.8.1 emits upstream compilation warnings on Elixir 1.20.4; Mix's
dependency compilation reports them separately from the project's warning gate.
They are not suppressed or represented as SmolBox diagnostics. The library and
developer tasks pass warning-as-error compilation. No dependency source was patched.

The repository currently has no configured Git remote. Source metadata and an
independent consumer review remain release prerequisites, not fabricated links
or evidence supplied by these examples.

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
operate without Keel/Jido and keep keys in private host files. macOS durable
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

`scripts/ci/package_consumer.py` builds the actual Hex tarball, bounds and
allowlists its members, extracts it into a private temporary directory, and
creates a fresh `MIX_ENV=prod` consumer. It checks a supplied fake-transport
health response and explicit Memory/SmolBox supervisor startup with no workers.
No worker API is contacted. Both the consumer and extracted SmolBox project
compile with warnings treated as errors. Package source hashes must remain
unchanged, and resolved dependencies/compiled modules must exclude CI and
example-only code. This smoke test does not replace real-worker qualification.

Run under the selected toolchain from `packages/smolbox`:

```sh
python3 scripts/ci/package_consumer.py \
  --report /absolute/new/consumer-current.json \
  --package-output /absolute/new/smolbox.tar
python3 scripts/ci/package_consumer.py --minimum \
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
passes locally; GitHub execution remains pending a repository remote. These
checks advance an independent acceptance item while resource certification and
public telemetry remain incomplete.
