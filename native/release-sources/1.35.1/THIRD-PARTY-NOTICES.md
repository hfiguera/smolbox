# Third-party notices for the SmolVM 1.35.1 Embedded Port bundles

SmolBox is distributed under the MIT license. Its helper incorporates the
Apache-2.0 SmolVM SDK at `bc58c3ef808e70db10c0ffb2b282c5f565ac6afc`.
The native package also carries the SDK license and upstream component notices.

The runtime uses libkrun at `e8fed93d25c340c91cf7e9d2cbbbda06f67c7a7f`
and libkrunfw at `0fae3853989a7fe5bf9921bc8e0d013e86c630e8`. The firmware
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

[Source bundle and checksums](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1.35.1)
