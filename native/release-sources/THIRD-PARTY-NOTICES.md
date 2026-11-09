# Third-party notices for Embedded Port

These notices cover the SmolBox Embedded Port release inputs for Apple Silicon,
Linux x86_64, and Linux ARM64, including the offline demo for each target. The
notice archive preserves the upstream copyright and license texts. The matching
source archive includes those texts, the upstream sources, and the packaging
inputs. Both archives and their SHA-256 checksums are available from the
[Embedded Port build inputs](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1).

## Host runtime

| Component | License and notice source |
| --- | --- |
| SmolBox Port helper | MIT. The bundle includes SmolBox's license. |
| SmolVM SDK | Apache-2.0. The bundle includes the SDK license and upstream component summary. The SDK code comes from the verified SmolBox source pin. |
| libkrun | Apache-2.0. The SmolVM release tag identifies the smol-machines/libkrun source, including upstream notices. |
| libkrunfw | LGPL-2.1-only. The staged firmware source contains its license and the architecture-specific build files. |
| Linux guest kernel and firmware patch set | GPL-2.0-only. The staged Linux 6.12.95 source and the exact firmware repository contain the kernel, patches and build instructions. |
| libepoxy | MIT. The staged libepoxy 1.5.10 source contains its copyright notice. |
| MoltenVK | Apache-2.0. The Homebrew recipe identifies MoltenVK 1.4.1 and the six separately licensed resources. Their original terms are in the source archive. |
| virglrenderer | The 0.10.4e-krunkit source contains its upstream licenses and notices. The SmolVM release tree carries the patches and build recipe. |
| Compiled Rust dependencies | The Rust inventory identifies the versions and dependency graphs for the helper, libkrun and guest Rust binaries. The notice archive preserves crate notices, and the source archive includes the lockfile-verified registry source archives. |

## Guest filesystem and demo payloads

| Component | License and notice source |
| --- | --- |
| Alpine packages | The APK inventory records the license and packaging revision from each installed package database. The source archive includes the original sources, recipes, patches and license texts. |
| SmolVM agent, guest runner, CUDA shims and Rosetta wrapper | The SmolVM v1.22.0 release tree supplies their sources, notices, and crate-level licenses. |
| Guest Vulkan stack | The RPM inventory records the package license declarations, binary RPMs and matching source RPMs. The archives provide the source RPMs and package payload notices for Mesa, Vulkan, Wayland, X11 and support libraries. |
| crane | Apache-2.0 for go-containerregistry v0.19.0. The archives include the Go toolchain and dependency sources and notices. |
| BusyBox | GPL-2.0-only. The BusyBox 1.37.0 source and matching Docker recipes cover the x86_64 and Apple Silicon demo layers. |
| Debian glibc and getconf in the BusyBox layers | The Debian source package for 2.41-12+deb13u4 contains the component-specific copyright and license terms. |
| Buildroot files in the BusyBox layers | See the Buildroot 2026.08 license, device table and system skeleton in the staged source. |

The source archive contains the download index, input checksums, and original
upstream locators. It includes the SmolBox and SmolVM code and recipes needed to
rebuild the helper and replace compatible firmware. The release tag supplies
the SmolBox source for the exact published helper. The binary release links to
these corresponding-source downloads for as long as the binaries are offered.
