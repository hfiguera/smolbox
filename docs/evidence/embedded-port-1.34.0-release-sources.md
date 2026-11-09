# Embedded Port SmolVM 1.34.0 release input review

This review covers the Apple Silicon, Linux x86_64 and Linux ARM64 input
archives pinned in the [release catalog](../../native/release-inputs.json).
The runtime archive hashes match the upstream [SmolVM 1.34.0 release](https://github.com/smol-machines/smolvm/releases/tag/v1.34.0).
The candidate still uses the approved demo and host disk-tool inputs from the
[1.22.0 review](embedded-port-release-sources.md).

- The helper builds from the unmodified SmolVM SDK at
  `d77eaf1c6eeff16bc8c258613746033e9bf567ca` and the SmolBox lockfile.
  The source bundle includes 735 registry crate archives verified against
  the native, SDK and libkrun lockfiles. [Rust dependency inventory](../../native/release-sources/1.34.0/rust.tsv)
- The runtime tag records libkrun at
  `cac2acc16c55453dd3a5e8c57ee5a7b81816dff4` and libkrunfw at
  `eab8d72d0778c8dd60ed9c97859145096670cc79`. The Linux libraries and
  Apple Silicon firmware match the tag's Git LFS hashes. All 14 file-backed
  sections of the Apple Silicon libkrun dylib match across the tag, upstream
  runtime and locally rebuilt candidate. The loader name changes to
  `@rpath/libkrun.dylib` for packaging. The firmware source includes its
  pinned Linux 6.18.60 kernel, patches, configurations and build scripts.
  [Binary inventory](../../native/release-sources/1.34.0/binaries.tsv)
- Each runtime contains 69 APK packages in its Alpine 3.24.4 guest rootfs.
  The source archive includes the 62 aports revisions for the agent and
  demo packages and their recipe and source files. Crane 0.22.1 was built
  with Go 1.26.10. Its 11 module archives match the upstream `go.sum`, and
  the Go standard library archive matches the Go release checksum.
  [APK inventory](../../native/release-sources/1.34.0/alpine.tsv) · [Go module inventory](../../native/release-sources/1.34.0/go-sources.tsv)
- The macOS graphics libraries and the guest Vulkan executable files
  match the previously reviewed bytes. Each demo's digest is unchanged.
  The source archive retains the earlier runtime, firmware, kernel and
  application inputs used by those demos. [1.22.0 review](embedded-port-release-sources.md)
- The source archive includes 1,403 indexed source inputs. The notice
  archive supplies the SDK notices and the corresponding license inventory
  for the runtime and demos. Each candidate build pins the notice archive
  digest. [Source index](../../native/release-sources/1.34.0/downloads.tsv) · [Third-party notices](../../native/release-sources/1.34.0/THIRD-PARTY-NOTICES.md) · [Published input archives](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1.34.0)

The separate candidate release is used to validate the exact GitHub-attested
archives through the public installer. [Live development qualification](smolvm-1.34.0-qualification.md)
