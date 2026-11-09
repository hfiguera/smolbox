# Embedded Port preview source and license review

This review covers the three local preview archives below and the corresponding
inputs approved for tagged candidate builds. Binary publication depends on the
checks against the final archives described below.
[Release procedure](../../native/release-review.md#prebuilt-release-procedure)

| Target | Preview archive SHA-256 | Native manifest SHA-256 |
| --- | --- | --- |
| Apple Silicon | `e1ddff59f352f73de24d469f8197a23676973ed5f361abc29a80cf6e43826978` | `3ed1158fb1a4fb2e6bdc377353702ac0ac615ed2b4cfbb45ea8a4d595eaa4ed0` |
| Linux x86_64 | `41ab15a7a0034d3678b27b86b7e2ddf7bad335a51e27993dd8ad26fe24113846` | `cce85464c0bb235d14fc026fbdbbe7ca8ed1ec9a3503d926fc05710ba5b37590` |
| Linux ARM64 | `6a05ffa4c6949ce70169221a20f8bcd29d8115f3996219bd967930de1997b368` | `a9b6517b9176306c86e53494ba5f9c00a0c562c778461e4ad04fb6e551d9b4ee` |

## Native helper and libraries

- SmolBox compiles its MIT-licensed Port helper with the unmodified
  Apache-2.0 SmolVM SDK at `9f446ae00219148ca4a703914f44a8e2fab11655`.
  The helper uses SmolBox's locked Cargo inputs. The native dependency
  inventory records the target-filtered normal dependency graphs from Cargo
  metadata, which can include dependencies the release linker eliminated.
  [SDK pin](../../native/vendor/source.json) · [Rust inventory](../../native/release-sources/rust.tsv)
- The firmware on all three targets matches the release archive and the Git
  LFS object at the SmolVM v1.22.0 release tag `f40f42c337319b724e221e8d3f809f7b186340c2`.
  The release-tag provenance identifies `libkrunfw` commit
  `b8c9994d121d2ba8853216aac68a135e3a4c93ac`. Its Makefile selects Linux
  6.12.95 and applies its patches and architecture-specific configurations.
  The staged source includes the firmware code, scripts, configurations,
  patches, and Linux 6.12.95 archive. This also covers the duplicate firmware
  in the standalone demo packs where the bytes match the same runtime.
  [Release-tag inputs](https://github.com/smol-machines/smolvm/tree/f40f42c337319b724e221e8d3f809f7b186340c2/lib) · [Firmware source](https://github.com/smol-machines/libkrunfw/commit/b8c9994d121d2ba8853216aac68a135e3a4c93ac)
- Both Linux `libkrun` binaries match the release archives and release-tag
  Git LFS objects. The tag records `libkrun` commit
  `3285db7404144ed61faf0848bb424c0f82743f41`. On macOS, after removing
  signatures from temporary copies, the preview and released `libkrun` differ
  only in the `__LINKEDIT` virtual size. The load commands identify the same
  libraries. The release-tag build and signing steps account for the provenance
  of the macOS input.
  [libkrun source](https://github.com/smol-machines/libkrun/commit/3285db7404144ed61faf0848bb424c0f82743f41) · [Binary inventory](../../native/release-sources/binaries.tsv)
- The three macOS graphics dylibs match the release bytes and tag Git LFS
  objects. The virglrenderer recipe pins `0.10.4e-krunkit` by SHA-256 and
  applies the SmolVM tag's virglrenderer patches. The dylibs for libepoxy
  1.5.10 and MoltenVK 1.4.1 match the Homebrew arm64 Tahoe bottles after
  normalizing the install names and removing signatures from temporary
  copies. The sources include the matching Homebrew recipe and all six
  MoltenVK resources pinned by that recipe.
  [virglrenderer build recipe](https://github.com/smol-machines/smolvm/blob/f40f42c337319b724e221e8d3f809f7b186340c2/scripts/build-virglrenderer-macos.sh) · [MoltenVK 1.4.1](https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.1)

## Guest filesystem and demos

- The Alpine 3.19 agent root filesystem contains 64 installed APK packages
  per target. The inventory records versions, declared licenses, and aports
  commits from the installed package databases. The same process covered the
  15 APK packages in the Linux ARM64 Alpine 3.21.8 demo. The 35 distinct
  aports revisions, their recipe files, and their checksum-listed inputs
  were staged. The Linux ARM64 demo has the same 88 regular-file contents
  as the digest-pinned OCI layer after unpacking.
  [APK inventory](../../native/release-sources/alpine.tsv) · [Alpine packaging source](https://github.com/alpinelinux/aports)
- The agent, CUDA compatibility shims, CUDA guest runner, and Rosetta
  wrapper are SmolVM release assets with code in the v1.22.0 source tree.
  The vendored `crane` binaries match the published go-containerregistry
  v0.19.0 Linux assets for both architectures. Both binaries identify the
  same Go 1.21.6 toolchain and 17 dependency modules. Their staged sources
  verify against the Go release checksum and the project's `go.sum`.
  The tagged guest graphics
  recipe pins 22 binary RPMs from COPR and AlmaLinux. All 22 RPM digests
  verified, and all 11 corresponding source RPMs named by their headers were
  staged. These provide the exact distro recipes and patches, including the
  patched Mesa Venus driver.
  [SmolVM guest build](https://github.com/smol-machines/smolvm/blob/f40f42c337319b724e221e8d3f809f7b186340c2/scripts/build-agent-rootfs.sh) · [Guest Vulkan recipe](https://github.com/smol-machines/smolvm/blob/f40f42c337319b724e221e8d3f809f7b186340c2/scripts/fetch-vulkan-guest-driver.sh) · [RPM source inventory](../../native/release-sources/vulkan.tsv)
- The x86_64 Linux and macOS demo layers match the BusyBox official image
  `diff_id` for their respective architecture. Both use BusyBox 1.37.0
  with Debian glibc 2.41-12+deb13u4. The pinned BusyBox Docker build recipes,
  patches, BusyBox source archive, and Debian glibc source package inputs
  were staged. The copied `getconf` and `libc.so.6` match Debian's binaries
  for both architectures. The BusyBox recipes also use the Buildroot 2026.08
  system skeleton.
  [ARM64 image recipe](https://github.com/docker-library/busybox/tree/54028ab642a011c458878f7393b1483f23ee1057/latest-1/glibc) · [x86_64 image recipe](https://github.com/docker-library/busybox/tree/7f8c76693ac4a64018eb67cf2768e5792d24bf6e/latest-1/glibc) · [Debian glibc source](https://deb.debian.org/debian/pool/main/g/glibc/)

## Rebuilding and approving replacement firmware

1. Verify the `libkrunfw` and Linux source archives against the
   [source downloads index](../../native/release-sources/downloads.tsv).
   Extract the firmware archive and put `linux-6.12.95.tar.xz` in its
   `tarballs/` directory. On the matching Linux architecture, run
   `make -j N LOCALVERSION=-smolbox-relink`, using the number of build
   jobs for `N`. The upstream recipe applies its patches and produces
   `libkrunfw.so.5.5.0` with SONAME `libkrunfw.so.5`. The marker lets
   the guest report which build it booted. The build needs the usual
   Linux kernel tools, including GCC, make, bc, bison, flex, OpenSSL and
   libelf headers, and Python with pyelftools.
2. For Apple Silicon, generate Darwin's `kernel.c` from the rebuilt
   Linux ARM64 `arch/arm64/boot/Image` with the firmware source's
   `bin2cbundle.py --os Darwin -t Image IMAGE kernel.c`. On the Mac,
   place it in a fresh copy of the same firmware source and run
   `make OS=Darwin`. The preview workflow ad-hoc signs
   `libkrunfw.5.dylib` and verifies that its install name matches the
   original.
3. On the target OS, work in a private copy of the original native
   package. Replace every `libkrunfw` filename listed under `lib/` in
   the original manifest with the rebuilt library, preserving file
   modes. The original approval binds the original bytes. From the
   corresponding SmolBox checkout, materialize the pinned SDK inputs
   with `python3 native/bootstrap.py`, then run
   `python3 native/package.py --executable COPY/smolbox-port --assets COPY --output NEW/package`.
   This reuses the compatible Port executable and writes a fresh native
   manifest. On macOS the builder applies its preview signature and
   hypervisor entitlement to the packaged helper.
4. Use [the release bundle builder](../../native/release_bundle.py)
   with the new package and the same demo. Approve the digest printed
   by the builder and install into a fresh directory.

   ```sh
   mix smolbox.embedded.install --tag TAG --install-dir NEW_INSTALL \
     --archive NEW_ARCHIVE --sha256 NEW_ARCHIVE_SHA256
   ```

   Set the Embedded Port target's manifest pin and identity from the
   new package. In a fresh domain, run the quickstart with a guest
   command that checks `uname -r` for `6.12.95-smolbox-relink`, then
   verify that SmolBox collects the command result, deletes the VM and
   releases its reservation.

This workflow covers firmware loaded by the Embedded Port. The standalone
demo stays byte-identical and its bundled libraries remain subject to the
source-delivery review.

### Local qualification

The replacement packages use the preview helpers and the unmodified SDK
revision recorded above. The native helper checks the old manifest before
starting an SDK domain. It returned a package preflight rejection when the
approved manifest was paired with the replacement library. For successful
consumer lanes, the installer verified the new archive digest, the guest
checked the kernel release marker and returned `42`, and SmolBox reported
complete collection and cleanup with zero reserved slots.

| Target | Rebuilt firmware SHA-256 | New manifest SHA-256 | New archive SHA-256 |
| --- | --- | --- | --- |
| Apple Silicon | `0661bacc00bd84744ea1d932a29dc0eb6f5f211125e1b7a0560875a101e84f3c` | `dc899c1423ae246c3ee5362d7040271cd1b8fded96b027ef37c014a6815cc85f` | `6f8351b8bbf388596e661235002853f70828ca18f568891d249b513c17d1b3ea` |
| Linux x86_64 | `8d2ad3458fb3a001b107a314703ebf767f8f32ef3e0c723e07392f2be10dfb4d` | `9e8720cc0a865a8a0d8c4e185c77272f3e754520dfc452ee01add86ca438b8ff` | `ff0358fcb7ac1b30ab3396690533b4783fcb8b50077cf72aa2b0becbb56d1c5a` |
| Linux ARM64 | `a5e3ad25f38eb217c44d22551ac626af2e8783912f6e95e90dd67240e0f42b15` | `cbd33001c45fa1baf12ec630d0b0bb770f3475fa65c9ad48d576ca471620ae3f` | `aba02a170be644e137c0312fcfa3472a47b6cf616951192d637451d609622223` |

Linux x86_64 and ARM64 both passed with Elixir 1.20.4 / OTP 29.0.6 and
Elixir 1.18.4 / OTP 27.3.4.15 in fresh standard accounts with KVM access.
The ARM64 runs used Lima. Each consumer environment ran without Rust,
and the test accounts had no remaining helper or VM processes after
normal shutdown.

The macOS replacement has the original install name and exported symbols,
verifies under ad-hoc signing, and changes only the two firmware entries
in the native asset inventory. Both toolchains passed the local archive
install and live guest checks in separate fresh standard macOS accounts,
with Gatekeeper enabled and without Rust. Both guests reported the rebuilt
kernel and returned `42`. SmolBox completed VM cleanup and released the
reservations, and neither account had a remaining helper or VM process.
Crash and CLI-race validation remains deferred.

## Approved candidate inputs

The [release input catalog](../../native/release-inputs.json) pins the exact
SmolVM v1.22.0 runtime archive and offline demo for each target. The runtime
archive digests match the upstream release. The demos match the bytes used in
the local quickstart and firmware replacement runs. The catalog also pins the
host disk tools, notice archive, and matching source archive.

| Target | Reviewed host tool |
| --- | --- |
| Apple Silicon | Homebrew e2fsprogs 1.47.4, arm64 Tahoe bottle, at `/opt/homebrew/opt/e2fsprogs/sbin/resize2fs` |
| Linux x86_64 | Ubuntu 24.04 amd64 e2fsprogs `1.47.0-2.4~exp1ubuntu4.1` at `/sbin/resize2fs` |
| Linux ARM64 | Ubuntu 24.04 arm64 e2fsprogs `1.47.0-2.4~exp1ubuntu4.1` at `/sbin/resize2fs` |

The Apple Silicon candidate uses ad-hoc signing with the hypervisor entitlement
and GitHub build attestation for the archive. The builder packages the SDK's
`@rpath/libkrun.dylib` from its private link directory and verifies the dylib
signatures. The approval covers the CLI installer path, with Gatekeeper enabled
during final qualification. Developer ID signing and notarization are outside
this candidate policy.

The input prerelease hosts the [matching source archive](https://github.com/hfiguera/smolbox/releases/download/embedded-port-inputs-v1/smolbox-embedded-sources.tar.gz),
the [notice archive](https://github.com/hfiguera/smolbox/releases/download/embedded-port-inputs-v1/smolbox-embedded-notices.tar.gz),
and the [download checksums](https://github.com/hfiguera/smolbox/releases/download/embedded-port-inputs-v1/SHA256SUMS).
The source archive contains the 426 verified entries from the
[source downloads index](../../native/release-sources/downloads.tsv) and 590
registry crate sources checked against the native, libkrun, and guest Cargo
lockfiles. It also carries the upstream build recipes, patches, license texts,
and component inventories. The candidate builder includes the verified notice
archive in each attested bundle. The binary release must link to the matching
source downloads and keep them available while the binaries are offered.

The published sources, notices, demos, and upstream runtime archives were
downloaded anonymously and verified against the catalog. Local Linux
packaging checks installed the pinned Ubuntu packages in clean containers,
confirmed both `resize2fs` digests, and assembled bundles with the reviewed
demo and notice bytes using the preview helpers. A local Apple Silicon build
from the pinned SDK passed the candidate packaging and installer checks,
including the packaged dylib signatures, hypervisor entitlement, and notice
archive digest.

## Final archive checks

1. Confirm the actual linked and bundled components against the
   [third-party notices](../../native/release-sources/THIRD-PARTY-NOTICES.md),
   including embedded C, Go, and graphics dependencies. Verify the final source
   and notice links against the published bytes.
2. Record the final archive and manifest digests, verify the build attestations,
   and confirm the macOS signatures and hypervisor entitlement.
3. Run the public CLI download and install on both toolchains per platform.
   Keep Gatekeeper enabled on macOS and verify the replacement workflow against
   the final archive. [LGPL-2.1 terms](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
