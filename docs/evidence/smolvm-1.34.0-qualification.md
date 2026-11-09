# SmolVM 1.34.0 qualification

The HTTP worker and the public Embedded Port distribution stay on 1.22.0 while
the 1.34.0 Embedded Port release inputs are reviewed. Both 1.34.0 candidates
passed the live checks recorded here. Earlier Embedded Port package identities
remain accepted under their original protocol and feature approvals.

The Embedded Port build uses the unmodified
[SmolVM 1.34.0 release](https://github.com/smol-machines/smolvm/releases/tag/v1.34.0)
at `d77eaf1c6eeff16bc8c258613746033e9bf567ca`. The candidate packages use the
matching release libraries, guest agent and disk templates. The distribution
builder checks the asset release against the compiled SDK pin before downloading
inputs. The local archives use the existing development packaging and the
previously approved, digest-verified offline demos.

| Platform | HTTP worker | Embedded Port |
| --- | --- | --- |
| Linux x86_64 | Ordinary and extended runtime coverage, PostgreSQL checkpoint recovery, stopped disk growth, persistent volumes, held branches, registry warm and verified export/reimport passed | Public managed binary PTY I/O and resize, held branches and backing cleanup passed on the rebuilt bundle. The public checkpoint campaign passed capture, two independent restores, cold restart, release and empty inventory. |
| Linux ARM64 | Live create, start, execute, stop, restart, retained data, deletion and empty inventory passed on nested KVM | Ordinary lifecycle, retained files across a graceful helper restart, observability, terminal preflight and empty inventory passed on the candidate rebuilt with the offline network fix. |
| macOS ARM64 | Liveness, file transfer, terminal, startup workload, port policy, checkpoint and extended execution passed in an isolated account. All four initial broad-suite failures passed focused reruns. Cold create and streamed-command stop passed with the standard client budgets after the client change. | The rebuilt archive and ad-hoc signatures verified. The direct Port lifecycle, public managed lifecycle and public checkpoint campaign passed. The managed campaigns used the standard 30-second lease. |

The Linux x86_64 HTTP tests observed exits after 305 seconds of silence in both
buffered and streaming execution. The PostgreSQL suites passed 25 runtime
recovery and three checkpoint recovery cases. Export was verified with the
worker's standard transfer limit. The lab worker capped at 16 MiB rejected the
flattened image because the same upstream setting caps pack export. Both
workers ended with empty inventories.

On macOS the worker also returned exits after 305 seconds of silence in
buffered and managed streaming execution. The worker ended with an empty
inventory. The file-cap rerun used the test's required 1 MiB worker setting.
SmolVM 1.34 extends the VMM exit-flush allowance from two to 15 seconds.
The HTTP stop test and delayed-exec fault gate allow 30 seconds for 1.34,
with the previous 10-second bounds for older runtimes. The cancellation
assertion checks the cleanup schedule against the timestamp of the record
that supplied it. With the old HTTP receive cap, a cold create timed out
and a stop returned uncertain at 15.004 seconds. Create and stop now use
the total operation budget for their quiet responses. The final cold create
and stop probe passed with default client budgets, with stop observed at
15.030 seconds and an empty inventory after deletion.

The Embedded Port checkpoint campaign used a 512 MiB seed with 1 GiB disks
and private archive entries. In the initial macOS run, the SDK produced a
checkpoint with virtio-net enabled from a record intended to be offline.
SmolVM 1.34 treats a present but empty CIDR or DNS host list as an explicit
network policy. SmolBox now omits both lists for offline guests and keeps
the explicit deny-all policy when a guest has published ports. Capture
preflight checks the SDK's effective device plan. Linux x86_64 passed the
entire checkpoint campaign after the fix. The first macOS rerun passed
recapture and two independent restores before a stop ended in an uncertain
state. With the standard 30-second lease, the complete macOS checkpoint
campaign passed, including cold restart, artifact removal and an empty SDK
inventory. The isolated accounts retain the earlier failed runs' evidence.

The SDK migration preserves the supported offline checkpoint and TCP port
contracts. Boot metadata is excluded from durable ownership hashes. Branch
boot and capture verify that the approved guest rootfs matches the source
before SDK dispatch. Historical branch proofs still validate against their
original SDK revision, while new SDK dispatch requires the current revision.
The candidate uses separate enrollment. The evidence covers existing package
approval and historical proof reads. Live adoption of a 1.22.0 domain requires
its own migration proof.

On macOS the public managed example was unstable with its one-second lease.
The public lifecycle with the standard 30-second lease passed disposable
cleanup, retained files, runtime restart, binary terminal I/O and resize.
The direct Port proof used the same approved packed fixture and helper build.

The deterministic Elixir suite passed 2,167 checks with 42 exclusions. The
independent clean SDK API check passed on macOS. The Linux Rust engine suite
passed 1,073 cases with 25 ignored and four fixture permission failures. Those
four passed in separate reruns after correcting the cached test executable's
mode. The Port and protocol suites passed 256 checks with two ignored, including
the additional regression for SDK revision validation. The macOS workspace
passed Clippy with warnings denied. The final x86_64 helper passed the managed
lifecycle and terminal proof on Elixir 1.18.4 and OTP 27.3.4.15 with Rust absent
from the consumer's path.
Twenty-five focused Rust tests passed after the offline network fix.

## Paired default promotion

The three local 1.34.0 development archives have verified digests. The
distribution input catalog still binds the runtime archives, notices and
corresponding source bundle reviewed for 1.22.0. The 1.34.0 tag records
different libkrun and firmware revisions
(`cac2acc16c55453dd3a5e8c57ee5a7b81816dff4` and
`eab8d72d0778c8dd60ed9c97859145096670cc79`). The
[prebuilt release procedure](../../native/release-review.md#prebuilt-release-procedure)
requires reviewing the replacement inputs and testing the final attested
archives via the public installer. Keep the HTTP default and the Embedded
Port distribution pin together until that review and installation pass.
