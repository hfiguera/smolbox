# Embedded Port SmolVM 1.35.1 candidate input review

The three candidate runtime archives match the official SmolVM `v1.35.1`
release at `bc58c3ef808e70db10c0ffb2b282c5f565ac6afc`. The SDK snapshot is
unmodified. This review records local source correspondence; public source
availability, hosted build provenance and public installer qualification are
still required before distribution approval or default promotion.

| Target | Runtime archive SHA-256 |
| --- | --- |
| Apple Silicon | `962142af8820f2c7dc5a03d755ed1fbecea418201ff24e4bad48d2cdd313de0e` |
| Linux x86_64 | `1c9377f6ada3c7c6753efada90595d5f44eb7a900ca0e4f8b786815b84fd22be` |
| Linux ARM64 | `554a3793009bdace519e46923d5f6466e17c126f4bb2111da874d45ef7e95cce` |

The Rust inventory (`native/release-sources/1.35.1/rust.tsv`) covers the
native helper, SDK guest agent and libkrun dependency graphs. Registry archives
are checked against their lockfile checksums. The complete source bundle also
retains earlier sources needed by the unchanged offline demo packs.

The runtime tag pins libkrun at
`e8fed93d25c340c91cf7e9d2cbbbda06f67c7a7f` and libkrunfw at
`0fae3853989a7fe5bf9921bc8e0d013e86c630e8`. Linux library bytes and Apple
Silicon firmware match the tag's Git LFS object hashes. All 14 file-backed
Mach-O sections match across the tag, runtime and packaged Apple Silicon
libkrun. Packaging changes its loader name to `@rpath/libkrun.dylib` and signs
an owned copy. The firmware source includes the pinned Linux 6.18.60 kernel,
patches, configurations and build scripts. See the
binary inventory (`native/release-sources/1.35.1/binaries.tsv`).

Each current runtime contains 69 Alpine 3.24.4 APK packages. The changed package
is crun 1.31-r0: its aports recipe at
`267ae2d4995f339f1d9fa82cb5bdab2510e28329` and source archive were verified
against the recipe's SHA-512 checksum. Earlier recipes and sources remain for
the unchanged runtime and demo components. Crane 0.22.1, Go 1.26.10, macOS
graphics libraries, guest Vulkan binaries and Rosetta inputs retain the reviewed
bytes from 1.34.0. See the APK inventory (`native/release-sources/1.35.1/alpine.tsv`)
and Go inventory (`native/release-sources/1.35.1/go-sources.tsv`).

The source index (`native/release-sources/1.35.1/downloads.tsv`) lists
1,416 verified source inputs. The staged source archive includes the SmolBox
native source, SDK, firmware, kernel, dependency archives, recipes and license
texts. The separate notice archive includes the SDK notices and component
license inventory. See the notices (`native/release-sources/1.35.1/THIRD-PARTY-NOTICES.md`).

The draft catalog is `native/release-inputs-1.35.1.json`, with distribution
approval set to false on all targets. Its staged sources bind native commit
`e548f4f336dced0c6c8125b87f8aa09bc33351ef`. The proposed input release is `embedded-port-inputs-v1.35.1`; it has not been
published. `native/release-inputs.json` continues to select the approved 1.34.0
inputs. Staged installation checks use an explicitly supplied archive digest
and do not establish hosted provenance or qualify a public download.

Live checks and outstanding gates are recorded in
[the qualification report](smolvm-1.35.1-qualification.json).

## Staged corresponding-source archives

| Archive | SHA-256 | Bytes |
| --- | --- | ---: |
| `smolbox-embedded-sources.tar.gz` | `cfb144d2ff587fad6a99828ee8fdb5df73cf74b5404e3d51d2398cf0084f45fa` | 1000306930 |
| `smolbox-embedded-notices.tar.gz` | `9b9593506bba5d74d3baca6ce9f82a065e6618ecc655057066f6b8ff4795467f` | 744820 |
