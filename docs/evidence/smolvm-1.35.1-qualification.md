# SmolVM 1.35.1 qualification

Completed local qualification supports the unmodified SDK at
`bc58c3ef808e70db10c0ffb2b282c5f565ac6afc`. At the user's explicit direction,
HTTP workers, checkpoint approvals, native source/release inputs and Kubernetes
lab pins now default to **1.35.1** on that local basis. Explicit older versions
remain supported. No SDK state, stored approval or historical evidence is migrated.

The [source/notices release](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1.35.1)
and attested stable native [`v0.6.1` bundles](https://github.com/hfiguera/smolbox/releases/tag/v0.6.1)
are public. All six stable public installer lanes passed in fresh standard OS
accounts: current/minimum Elixir/OTP on Apple Silicon, Linux x86_64 and Linux
ARM64, with Rust absent. Current lanes exercised automatic tag selection and
minimum lanes exercised explicit `--tag v0.6.1`. Every temporary account, HOME
and account lock was removed after positive SDK cleanup and post-use asset
verification. **Hex remains unpublished**; use the matching Git tag and native
installer tag. Existing published bundles keep their original identities.

The [stable installer report](embedded-port-0.6.1-public-installers.json) binds
these exact hosted binaries to their source commit, attestations, archive and
manifest hashes, and six consumer results. The earlier
[RC installer report](embedded-port-1.35.1-public-installers.json) and broader local
campaigns below retain their original package identities and scope.

The [machine-readable report](smolvm-1.35.1-qualification.json) binds each native
campaign to its package, executable and asset digests. Historical evidence and
approvals retain their original identities.

## Compatibility changes

- Native telemetry accepts bounded legacy decimal and 1,024-byte padded egress
  samples. Malformed samples stay unavailable; oversized samples fail closed.
- Rootfs approval recognizes the SDK's exact legacy macOS digest of the same
  approved tree. Historical 1.22.0/1.34.0 branch intent hashes remain readable;
  dispatch still requires the active SDK identity. Bare branch/capture rejects
  six unsupported SDK settings and verifies the effective source profile.
- Capture and branch workers receive HOME from the verified SDK namespace after
  clearing their environment. SQLite integration handles the updated SDK's
  fallible progress-handler installation.
- Explicit terminal arguments preserve empty arguments, spaces and literal
  metacharacters. Nonempty arguments require HTTP 1.35.1 or native
  `terminal_arguments: 1`. Generated scripts use an interpreter supplied by the
  image. Existing program-only calls and fingerprints retain their old behavior.
  Selective codec v55 requires upgraded shared readers before writing these
  records; the store capability gate enforces that requirement.
- Export retirement binds the SDK's exact known logs, sockets and empty private
  attachment roots. Metadata stays bounded. Directory removal never traverses
  attached content, and replacements or foreign entries remain rejected.

## Completed local checks

| Target | Native runtime campaigns | HTTP campaigns |
| --- | --- | --- |
| Apple Silicon | Ordinary lifecycle and retained files; public binary PTY/resize and literal argv; PostgreSQL lifecycle/argv; checkpoint capture, two independent restores and release; container export/reimport and registry cold/warm; compatible same-SDK helper upgrade | Ordinary/extended suites and three terminal cases; PostgreSQL recovery and checkpoint cases |
| Linux x86_64 | Ordinary lifecycle, public PTY/argv, strict-floor network and mapped ports in an isolated loopback-only namespace; held branches and checkpoint capture/restore/release; PostgreSQL growth and volumes across separate normal BEAM runs; export/reimport, registry cold/warm, pinned OCI creation/pulls/inventory and configured startup; compatible same-SDK helper upgrade | Ordinary/extended suites and three terminal cases |
| Linux ARM64 | Ordinary lifecycle, retained files, public PTY/argv, padded telemetry and compatible same-SDK helper upgrade on nested KVM | Create/start/exec/stop/restart/delete, binary transfer, retained data, measurements and empty inventory |

Each final native package produced its own 1,024-byte telemetry sample. Successful
campaigns confirmed owned deletion and zero reservations or empty SDK inventory
as applicable. Failed attempts keep their original evidence; successful cleanup
of a later campaign does not release an earlier uncertain reservation.

HTTP positive port probes against private responder addresses used an explicit
metadata egress floor on dedicated workers, as in 1.34.0. Production defaults
remain strict. The separate native network campaign exercised the strict floor
with public-address aliases inside its isolated network namespace.

The final staged bundles passed six no-Rust installer/consumer cases: all three
targets on current and minimum Elixir/OTP. Each extracted the actual Hex archive,
verified an explicitly supplied bundle digest and notices, printed `42` in a
guest and completed VM cleanup. These used fresh HOME, Mix and GitHub CLI
configuration directories under existing non-root UIDs. They do **not** qualify
fresh OS accounts, public downloads or hosted provenance. The ARM64 minimum OTP
is 27.3.4.17; the other minimum lanes use 27.3.4.15, all with Elixir 1.18.4.

A follow-up passed both macOS lanes in fresh, password-disabled,
non-admin standard accounts with their real registered HOME directories. Rust
was absent, Gatekeeper stayed enabled, signatures and the hypervisor entitlement
verified, the guest printed `42`, and cleanup left zero VM rows. All 808 installed
assets verified after use. Both temporary accounts, HOME directories and account
locks were removed after their processes exited. Provisioning and account
removal used the native macOS authorization flows. These staged checks still do
not establish public-download provenance.

The final Elixir CI suites passed 2,323 checks on macOS and 2,322 on Linux, with
42 runtime exclusions each. Final Rust workspace checks passed 1,349 on macOS
and 1,350 on Linux, with 27 reviewed ignored cases each. Strict Clippy, Rustdoc,
SDK integrity, 64 native Python checks (four platform skips), 78 Kubernetes Python
checks, documentation generation and local links across 162 pages passed.
PostgreSQL passed 310 store cases plus 25 HTTP controller-recovery and three HTTP
checkpoint-recovery cases. These controller fault boundaries do not establish
native helper/VMM process-loss qualification.

A fresh Kubernetes lab passed nine phase0 probes and binary, silent, cancellation
and overflow public controller cases with both Memory and PostgreSQL. Final
cleanup reports have zero charges and no remaining SmolVM RuntimeClass pods.
The separate 1.35.1 source/critical-region reviews accompany the explicit runtime
pins; the raw phase0 harness's older source-basis metadata was preserved.

## Default promotion verification

The promotion reran full macOS `mix ci`: 2,323 checks passed, 42 runtime cases
excluded, and all static analysis passed. The initial run exposed a stale default
admission fixture, which was corrected, plus two short-deadline failures at
32 concurrent cases. The complete rerun used four BEAM schedulers/eight concurrent
cases and passed without changing deadlines or production behavior.

Fresh packaged production consumers passed on Elixir 1.20.5/OTP 29.1.2 and
Elixir 1.18.4/OTP 27.3.4.15 with exact minimum dependencies, both without Rust on
PATH. They confirmed the 1.35.1 default and existing API compatibility. These
package/default checks started no native VM; the exact-package live evidence
above remains the native qualification basis. All 64 native Python cases (four
platform skips), 78 Kubernetes Python cases, warning-as-error documentation and
local links across 162 pages passed. Default input catalogs and Kubernetes source
reviews agreed with their reviewed 1.35.1 versions; distribution approval was false
on every target during that default-promotion check.

## Public distribution qualification

The [corresponding-source review](embedded-port-1.35.1-release-sources.md)
records 1,416 verified inputs. Anonymous public source/notices downloads match
the reviewed hashes. All three native bundles were built and attested on
GitHub-hosted runners from tag `v0.6.1-rc.1`, commit
`626b0a8f706c5246267a83f946d3e26a88a24c82`, and published without changing the
latest stable release. The matching input catalogs are approved for this native
qualification prerelease.

The exact public installer route passed six times in fresh standard accounts:

| Platform | Current toolchain | Minimum toolchain | Result |
| --- | --- | --- | --- |
| Apple Silicon | Elixir 1.20.5 / OTP 29.1.2 | Elixir 1.18.4 / OTP 27.3.4.15 | Both passed; Gatekeeper enabled and signatures/entitlement verified |
| Linux x86_64 | Elixir 1.20.4 / OTP 29.0.6 | Elixir 1.18.4 / OTP 27.3.4.15 | Both passed in the dedicated nested-KVM guest |
| Linux ARM64 | Elixir 1.20.5 / OTP 29 | Elixir 1.18.4 / OTP 27.3.4.17 | Both passed in the dedicated Lima nested-KVM guest |

Each lane used empty GitHub CLI configuration and no Rust on PATH. The unmodified
installer downloaded the public archive and bundle, enforcing repository ID,
workflow, tag and hosted-runner provenance. A read-only verifier fixture recorded
exact download hashes before delegating to the official GitHub CLI. Each guest
printed `42`; SDK VM and create-reservation rows ended at zero. All 808 macOS,
806 Linux x86_64 and 807 ARM64 assets verified after use. Temporary accounts,
HOME directories and account locks were removed; the task's Linux test guests
were normally stopped.

Initial Linux harness attempts failed at the Elixir version probe because the
operator's private working directory was inaccessible. No installer or VM was
dispatched. Their empty test accounts were collected after proving no SDK state,
locks or processes existed, logs were preserved, and fresh accounts passed after
setting the working directory explicitly.

See [exact public identities and results](embedded-port-1.35.1-public-installers.json).
Hex publication remains unauthorized and no candidate Hex release exists.

No SDK-revision domain migration, codec rollback or additional native crash
qualification is inferred from these ordinary campaigns. Retain existing worker
versions and approvals, or drain and enroll a separate 1.35.1 deployment.
