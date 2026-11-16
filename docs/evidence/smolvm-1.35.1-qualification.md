# SmolVM 1.35.1 qualification candidate

Local qualification passes for the unmodified SDK at
`bc58c3ef808e70db10c0ffb2b282c5f565ac6afc`. Defaults remain **1.34.0** for
HTTP workers, checkpoints, Kubernetes and the public embedded installer. Public
source delivery, hosted provenance and clean-account public installation remain
open gates. This candidate has not been published or approved for distribution. The user
requested that artifacts remain unpublished; the public distribution gates are
therefore intentionally pending.

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

## Remaining publication gates

The [corresponding-source review](embedded-port-1.35.1-release-sources.md)
records 1,416 verified source inputs and the staged source/notices archives.
`native/release-inputs-1.35.1.json` is a draft with distribution approval false;
the active catalog continues to select 1.34.0.

Before promotion, complete the repository's
[release process](../../native/release-review.md):

1. Publish and independently verify the reviewed corresponding-source and notice
   inputs, proposed as `embedded-port-inputs-v1.35.1`.
2. Build and attest all three targets from the matching qualification tag,
   proposed as `v0.6.1-rc.1`.
3. Verify the exact public downloads with current/minimum toolchains, Rust absent
   and fresh standard accounts. Keep Gatekeeper enabled on macOS. Fresh macOS test
   accounts can be provisioned through the native administrator authorization
   flow, which the staged follow-up above exercised successfully.
4. Record those identities and results before changing paired defaults.

No SDK-revision domain migration, codec rollback or additional native crash
qualification is inferred from these ordinary campaigns. Retain existing worker
versions and approvals, or drain and enroll a separate 1.35.1 deployment.
