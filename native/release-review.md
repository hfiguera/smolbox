# Embedded Port release review

The local SDK 1.34.0 candidates have a separate
[qualification record](../docs/evidence/smolvm-1.34.0-qualification.md).
The approved distribution inputs below still refer to SDK 1.22.0.

The release inputs for the three Embedded Port targets are approved for
candidate builds. **Binary publication remains gated** on checking the
resulting payloads and qualifying the public install.

## Integrity and provenance

The approved distribution uses SDK 1.22.0 revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. Bootstrap verifies the source archive,
complete unmodified content/mode inventory and lock inputs recorded in
`vendor/source.json`. It rejects patch lists and native Cargo source overrides.
The earlier clean engine-0.1.0 development packages have their own ordinary
Linux/macOS platform/consumer evidence. Those results remain attached to their
exact identities. Expanded engine-0.2.0 packages need their own source, policy,
asset and ordinary feature acceptance. At source 766b3a11, the isolated macOS
build passes eight compile/package/signature/source-integrity stages on manifest
947ad46c/helper 407bcee7; this is build evidence, with native qualification still
pending. See the [current completion audit](../docs/design/embedded-port-http-parity-completion-audit.md)
and [scoped build record](../docs/evidence/embedded-port-http-parity-macos-build-766b3a11.json).
The matching [Linux build](../docs/evidence/embedded-port-http-parity-linux-build-766b3a11.json)
passes 12 stages, 1,322 workspace tests (24 ignored) and 13 witness models on
manifest 0faf74dc/helper 2655ed9b. Neither build starts a native owner or VM.
Old patched package identities and proof results remain historical. A digest establishes
integrity of approved bytes; it is not publisher authentication or a reproducible
build attestation.

The [corrected macOS ordinary package](../docs/evidence/embedded-port-http-parity-macos-relay-ordinary-7b05cf60.json) at source 7b05cf60 uses manifest 0735ee82/helper d1f8a583. Exact current/minimum no-Rust public consumers now pass offline local-container lifecycle/files/managed terminals, draining, normal stopped-machine Runtime replacement with Memory alive and owned cleanup. All 809 assets verify after use; original build inputs retain their bytes and modes. This scoped development acceptance does not supply full HTTP parity, changed-helper upgrade, crash qualification, publisher authentication or distribution approval. Earlier failed attempts keep their own preserved evidence.

The [f1f250d3 source/image package](../docs/evidence/embedded-port-http-parity-macos-public-sources-f1f250d3.json)
adds four scoped macOS current/minimum no-Rust public consumers on manifest
1a8e644f/helper fe85a410. Configured OCI/images and offline bare registry
cold/warm workflows pass binary files, normal Runtime replacement and owned
cleanup. All 656 installed files and seven proof inputs per consumer verify;
both private archives and semantic v19 readers verify. SDK tables and native
process inventories end empty, the account lock is free and all 809 package
assets unchanged. This is development feature acceptance. Publisher signing,
notarization, firmware/source correspondence and license delivery remain open;
no broader parity, helper-upgrade or crash qualification is inferred.

The updated builder includes `SMOLBOX-LICENSE`, `SMOLVM-LICENSE`,
`SMOLVM-LICENSES.md` and `NATIVE-SOURCE.json` in the hashed asset inventory. Earlier
packages carried two SDK license files outside that inventory. These packages have
distinct manifest and asset digests; evidence does not transfer between them.
`NATIVE-SOURCE.json` identifies the pinned SDK archive/inventory. It is not a
complete SmolBox source-commit, dependency or firmware attestation. Separate
source inventories and build records must bind the helper's actual engine and
bridge source to its executable digest.

Earlier clean engine-0.1.0 packages use manifest schema 2. They require the exact compiled policy in
both the manifest and hashed `SMOLBOX-POLICY.json`, plus exact compiled source
metadata in hashed `NATIVE-SOURCE.json`. Policy version 1 records exclusive
cooperating domain ownership, observation schema 1, and versions of SmolBox's
transfer supervisor, boot guard and asset preparation; Rustler remains disabled.
Configuration binds these fields through its approved manifest SHA-256. Public
Policy now also binds Port protocol minor 4 and native cancellation grace. The
epoch-bound unavailable notice preserves ownership and capacity while stopping
admission. Approved legacy schema 1 / Hello 1.3 packages retain their original
limits and cannot satisfy a clean manifest. Old manifest approvals cannot be
substituted for changed source/build/asset/policy identities. This integrity check
does not authenticate a publisher or establish firmware correspondence.

Expanded engine-0.2.0 packages use manifest schema 3, policy schema 2,
configuration schema 2 and Port protocol 2.0. SDK version/revision remain
independent of those SmolBox versions. The compiled platform policy, SDK feature
versions, limits, hashed policy/source metadata and approved package identity
must agree. Optional descriptor presence is not ordinary qualification, and
the [current admission audit](../docs/evidence/embedded-port-http-parity-current-admission-audit.json)
records required features still absent from the Linux/macOS approval policies.
Legacy 1.3/1.4 readers and older receipts keep their own versions; a changed
package cannot adopt their operational authority by relabelling it.

macOS builds must give the unmodified SDK a private working library copy through
`LIBKRUN_BUNDLE`: upstream build logic rewrites/re-signs that directory. The
[recorded input-mode incident](../docs/evidence/embedded-port-http-parity-macos-build-input-mode.json)
and subsequent isolated rebuild distinguish successful package signing from input
preservation. Neither action opens the quarantined SDK domain or grants native
feature acceptance.

The macOS CLI candidate policy uses ad-hoc signing with the hypervisor
entitlement. The installer authenticates the enclosing archive with GitHub
build attestation. The final candidate must pass a clean-account test of
the exact public download and install path with Gatekeeper enabled. The
package builder retains its explicit `--signing-identity` option for a
separately qualified Developer ID distribution.

## License and source delivery gaps

SmolBox supplies its MIT license; the verified SDK supplies Apache-2.0 texts and
its upstream component summary. The inspected [libkrun license](https://github.com/libkrun/libkrun/blob/3285db7404144ed61faf0848bb424c0f82743f41/LICENSE)
is Apache-2.0. Upstream [libkrunfw licensing](https://github.com/libkrun/libkrunfw#license)
distinguishes LGPL library code and GPL kernel/patches and describes corresponding
source delivery with distributed binaries.

The SDK's generic component versions do not establish correspondence with every
actual packaged library and firmware binary. Research checkout revisions are not
binary attestations. Before distribution, inventory all linked Rust dependencies,
copyrights and notices; establish the exact libkrun, firmware and kernel versions,
configuration, patches and build recipes; provide applicable corresponding sources
and satisfy delivery/relinking obligations. Audit the guest agent and root filesystem
packages as well. Copying license texts alone does not close this gate.

The [source review](../docs/evidence/embedded-port-release-sources.md) maps all
three approved inputs to upstream artifacts and inventories their native,
guest, and demo contents. It records the firmware source, verified public
source downloads, notice delivery, and final archive checks.

## Development admission and distribution gate

Public Runtime admission accepts explicitly configured development Port targets.
Historical patched-package lifecycle campaigns cover ordinary startup, execution,
file collection, draining, normal Runtime restart with a surviving store and owned
deletion. Selected Linux boot/helper-loss and macOS durable interruption cases also
passed for those historical packages. These results do not qualify new clean
packages. Their identities and scope remain separate from clean qualification.
The new [clean-package evidence](../docs/evidence/embedded-port-unmodified-sdk-ordinary.json)
records passing macOS ordinary lifecycle, current/minimum public consumers,
PostgreSQL-backed Runtime replacement and compatible clean helper replacement.
Both platforms passed current/minimum public consumers, PostgreSQL-backed normal
Runtime replacement, compatible clean helper replacement and bare-VM snapshot
import/retention. The PostgreSQL lifecycle uses
ordinary Runtime shutdown with its store alive, without injected persistence loss.
The remaining crash/CLI-race campaign is deferred at the user's request;
complete crash qualification is not claimed. The latest
[progress record](../docs/design/embedded-port-progress.md) preserves tested scope,
an unresolved Linux verification failure and the stop request.

Distribution approval remains separate: complete independent SDK interference
races when separately authorized, exact native source/license delivery, publisher
provenance and distribution signing, then rerun consumers against the resulting
bytes. Ordinary HTTP-parity completion also requires all current operation,
source, platform, durable-store and upgrade gates in the completion audit;
historical offline qualification cannot close them. No native package is
published by this change. Local manifest approval is not publisher authentication.

## Prebuilt release procedure

The manual [release workflow](../.github/workflows/smolbox-embedded-release.yml)
builds Apple Silicon, Linux x86_64, and Linux ARM64 candidates on GitHub-hosted
runners. It requires an explicit Git tag matching the Mix package version and
an approved entry in the [release input catalog](release-inputs.json) for each
target. Each entry pins the runtime archive, standalone offline demo, host tool
package and installed executable. The shared entries pin the notices and source
archive. Repeat the input review before changing a pin.

The runtime input has one enclosing directory with `lib/`, `agent-rootfs/`,
and the two `.ext4.zst` disk templates. The builder expands the templates,
includes the verified notices, and checks that its `resize2fs` matches the
reviewed path and digest. The installer checks the same values on the consumer
host. List the supported host profiles and link the matching sources in the
binary release notes.

1. Configure deployment protections for the `embedded-port-release` GitHub
   environment, then dispatch the workflow on the release tag.
2. Keep the platform archives and their matching `.sigstore.jsonl`
   bundles together. The workflow emits candidates as run artifacts. Release
   assets use these same filenames and bytes.
3. Qualify the release installation from a fresh standard account on each
   target with current and minimum Elixir/OTP and without Rust on
   `PATH`. Verify the public attestation and run the offline command through
   cleanup. On macOS, leave Gatekeeper enabled and use the download method
   from the quickstart.
4. Record the exact tag, archive and manifest digests, host profiles, and
   consumer results. Make Embedded Port the default quickstart after the
   verified assets and the matching Hex package are available.

### Local installation preview

Local candidates built from native source at SmolBox commit `54618c8f` used
the test-only tag `v0.5.0-rc.1` in the archive envelope. The installer checked
an independently supplied archive digest after a loopback download. All four
lanes ran without Rust on `PATH` in dedicated standard accounts. Elixir
1.20.4 / OTP 29.0.6 and Elixir 1.18.4 / OTP 27.3.4.15 each printed `42`,
deleted the disposable VM, and released the reservation.

| Platform | Archive SHA-256 | Manifest SHA-256 | Test setup |
| --- | --- | --- | --- |
| Apple Silicon | `e1ddff59f352f73de24d469f8197a23676973ed5f361abc29a80cf6e43826978` | `3ed1158fb1a4fb2e6bdc377353702ac0ac615ed2b4cfbb45ea8a4d595eaa4ed0` | Ad-hoc signing and Gatekeeper enabled. |
| Linux x86_64 | `41ab15a7a0034d3678b27b86b7e2ddf7bad335a51e27993dd8ad26fe24113846` | `cce85464c0bb235d14fc026fbdbbe7ca8ed1ec9a3503d926fc05710ba5b37590` | KVM lab with staged Hex dependencies for offline use. |

The macOS input inventory matched all 404 regular guest-rootfs files, the
versioned firmware library, MoltenVK, epoxy, and virglrenderer against the
upstream 1.22.0 macOS archive. The packaged `libkrun.dylib` differed at the
binary level. This comparison leaves corresponding-source and notice delivery
open. Qualification of the tagged GitHub workflow, public attestation
verification, and the final release assets is still pending.

### Linux ARM64 Lima preview

The Linux ARM64 preview ran in Ubuntu 24.04 under Lima on Apple Silicon,
using nested KVM and Linux `6.8.0-147-generic`. The helper was built from the
same unmodified SDK revision as the other targets. Runtime libraries and the
agent rootfs came from the verified upstream `smolvm-1.22.0-linux-arm64.tar.gz`
release asset. The offline Alpine fixture used the pinned OCI image and
included the matching Linux ARM64 libraries inline. The bundle supplied the
disk templates.

| Input | SHA-256 |
| --- | --- |
| Upstream runtime archive | `069f34e4840313cf8fe163e0324c5f74756aa8296ee9238e46268e23ce5531a9` |
| Alpine OCI image | `0a7ed0d449b9318548e66674610d757de19b7645759f74b587b610b59d6b43fd` |
| Quickstart demo | `11ee6ae490cdc148d398a40aeda571c5fd2cfaf9d706faa4070741df3f08c0dd` |
| Native manifest | `a9b6517b9176306c86e53494ba5f9c00a0c562c778461e4ad04fb6e551d9b4ee` |
| Preview release archive | `6a05ffa4c6949ce70169221a20f8bcd29d8115f3996219bd967930de1997b368` |
| Host `/sbin/resize2fs` | `e742981c302ad5efec590381e22910180447052f0b5eb6b999c16a4ca6da68d9` |

Elixir 1.20.4 / OTP 29.0.6 and Elixir 1.18.4 / OTP 27.3.4.15 used separate
standard accounts without Rust on `PATH`. Both installed the digest-verified
preview archive, printed `42` in an offline guest, and released the VM and its
reservation. Both SDK databases ended with zero VMs and create reservations.
The evidence covers the local Embedded Port quickstart. Broader ARM64 feature
qualification and the public release path remain separate.
