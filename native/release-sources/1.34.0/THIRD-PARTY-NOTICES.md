# Third-party notices for the SmolVM 1.34.0 Embedded Port bundles

SmolBox is distributed under the MIT license. Its helper incorporates the
Apache-2.0 SmolVM SDK at `d77eaf1c6eeff16bc8c258613746033e9bf567ca`.
The native package also carries the SDK license and upstream component notices.

The runtime uses libkrun at `cac2acc16c55453dd3a5e8c57ee5a7b81816dff4`
and libkrunfw at `eab8d72d0778c8dd60ed9c97859145096670cc79`. The firmware
source includes LGPL-2.1 library code and the GPL-2.0 Linux 6.18.60 kernel
and patches. The source bundle includes these revisions, build scripts,
configurations and license texts.

The guest filesystem uses Alpine 3.24.4. Its APK packages and licenses are
listed in `alpine.tsv`. The agent, CUDA shims, and Rosetta wrapper come from
the SmolVM source tree. The bundled crane 0.22.1 uses Go 1.26.10.
The release retains the reviewed Mesa Venus and dependency RPMs. The macOS
graphics libraries remain at the previously reviewed versions of
virglrenderer, MoltenVK and libepoxy.

The offline demo packs are byte-identical to the previously reviewed
1.22.0 inputs. The source archive retains their corresponding earlier
firmware, kernel, runtime and application sources alongside the updated
runtime sources. Source and license inventories accompany the archives.

[Source bundle and checksums](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1.34.0)
