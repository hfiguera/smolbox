# Third-party notices for the Embedded Port preview

Draft for the three reviewed local previews. Publication and the final
notice set require the checks in the
[source and license review](../../docs/evidence/embedded-port-release-sources.md).
This index identifies the original notices and source materials for review.

## Host runtime

| Component | License and notice source |
| --- | --- |
| SmolBox Port helper | MIT. The bundle includes SmolBox's license. |
| SmolVM SDK | Apache-2.0. The bundle includes the SDK license and upstream component summary. The SDK code comes from the verified SmolBox source pin. |
| libkrun | Apache-2.0. The SmolVM release tag identifies the smol-machines/libkrun source, including upstream notices. |
| libkrunfw | LGPL-2.1-only. The staged firmware source contains its license and the architecture-specific build files. |
| Linux guest kernel and firmware patch set | GPL-2.0-only. The staged Linux 6.12.95 source and the exact firmware repository contain the kernel, patches and build instructions. |
| libepoxy | MIT. The staged libepoxy 1.5.10 source contains its copyright notice. |
| MoltenVK | Apache-2.0. The staged Homebrew recipe identifies the exact MoltenVK release and the six separately licensed resources. Preserve the notices from those sources. |
| virglrenderer | The staged 0.10.4e-krunkit source contains its upstream licenses and notices. The SmolVM release tree carries the patches and build recipe. |
| Compiled Rust dependencies | Use each crate's declared license and source notice. The [Rust inventory](rust.tsv) identifies the version and build graph for the helper, libkrun and guest Rust binaries. |

## Guest filesystem and demo payloads

| Component | License and notice source |
| --- | --- |
| Alpine packages | The [APK inventory](alpine.tsv) records the license and packaging revision from each installed package database. The original licenses and notices come from those exact source inputs. |
| SmolVM agent, guest runner, CUDA shims and Rosetta wrapper | Use the source and notices from the SmolVM v1.22.0 release tree, including its crate-level licenses. |
| Guest Vulkan stack | The [RPM inventory](vulkan.tsv) records package license declarations, exact binary RPMs and matching source RPMs. Use the source RPMs and package payload notices for the actual Mesa, Vulkan, Wayland, X11 and support libraries. |
| crane | Apache-2.0 for go-containerregistry v0.19.0. Preserve applicable notices for Go and its compiled modules. |
| BusyBox | GPL-2.0-only. The staged 1.37.0 source and matching Docker recipes include the inputs for both preview layers. Preserve the BusyBox license and the notices for the other components in those layers. |
| Debian glibc and getconf in the BusyBox layers | The Debian source package for 2.41-12+deb13u4 contains the component-specific copyright and license terms. |
| Buildroot files in the BusyBox layers | See the Buildroot 2026.08 license, device table and system skeleton in the staged source. |

The [source downloads index](downloads.tsv) lists the prepared files, checksums
and upstream locators. Keep the corresponding-source downloads and the final
license texts available with the release binaries.
