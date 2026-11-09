# Embedded Port SmolVM 1.34.0 release input review

This review covers the Apple Silicon, Linux x86_64 and Linux ARM64 input
archives pinned in the [release catalog](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-inputs.json).
The runtime archive hashes match the upstream [SmolVM 1.34.0 release](https://github.com/smol-machines/smolvm/releases/tag/v1.34.0).
The candidate still uses the approved demo and host disk-tool inputs from the
[1.22.0 review](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/docs/evidence/embedded-port-release-sources.md).

- The helper builds from the unmodified SmolVM SDK at
  `d77eaf1c6eeff16bc8c258613746033e9bf567ca` and the SmolBox lockfile.
  The source bundle includes 735 registry crate archives verified against
  the native, SDK and libkrun lockfiles. [Rust dependency inventory](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/rust.tsv)
- The runtime tag records libkrun at
  `cac2acc16c55453dd3a5e8c57ee5a7b81816dff4` and libkrunfw at
  `eab8d72d0778c8dd60ed9c97859145096670cc79`. The Linux libraries and
  Apple Silicon firmware match the tag's Git LFS hashes. All 14 file-backed
  sections of the Apple Silicon libkrun dylib match across the tag, upstream
  runtime and locally rebuilt candidate. The loader name changes to
  `@rpath/libkrun.dylib` for packaging. The firmware source includes its
  pinned Linux 6.18.60 kernel, patches, configurations and build scripts.
  [Binary inventory](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/binaries.tsv)
- Each runtime contains 69 APK packages in its Alpine 3.24.4 guest rootfs.
  The source archive includes the 62 aports revisions for the agent and
  demo packages and their recipe and source files. Crane 0.22.1 was built
  with Go 1.26.10. Its 11 module archives match the upstream `go.sum`, and
  the Go standard library archive matches the Go release checksum.
  [APK inventory](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/alpine.tsv) · [Go module inventory](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/go-sources.tsv)
- The macOS graphics libraries and the guest Vulkan executable files
  match the previously reviewed bytes. Each demo's digest is unchanged.
  The source archive retains the earlier runtime, firmware, kernel and
  application inputs used by those demos.
- The source archive includes 1,403 indexed source inputs. The notice
  archive supplies the SDK notices and the corresponding license inventory
  for the runtime and demos. Each candidate build pins the notice archive
  digest. [Source index](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/downloads.tsv) · [Third-party notices](https://github.com/hfiguera/smolbox/blob/b974b1d581844f73ff55306f6a465b7a45dd98dc/native/release-sources/1.34.0/THIRD-PARTY-NOTICES.md) · [Published input archives](https://github.com/hfiguera/smolbox/releases/tag/embedded-port-inputs-v1.34.0)

## Public installer validation

The hosted workflow built and attested all three archives from tag
`v0.5.1-rc.1` at `b974b1d581844f73ff55306f6a465b7a45dd98dc`. The installer
verified the signing workflow, source tag and repository identity for each
public download. Each install also matched the approved host `resize2fs`.
[Hosted build](https://github.com/hfiguera/smolbox/actions/runs/42705633839) · [Attested prerelease](https://github.com/hfiguera/smolbox/releases/tag/v0.5.1-rc.1)

| Target | Archive SHA-256 | Installed manifest SHA-256 |
| --- | --- | --- |
| Apple Silicon | `f5fed45f36db9a4f24ad02768d98a07a8a8a58b084f120272368ac0a8888ed6a` | `4fa118a84131feb985b9ca87d3f8e80b4ecb7669721dedd2426d970313d9d5e4` |
| Linux x86_64 | `e4b46f248de74eaa244ad6702a6a9dd62c54c22d6b5d6dd3eb40e2ca14866974` | `fc9efb7aa19e8bea00d1c861acdf40b4dde9b14ea3b7bdccf472351031b41042` |
| Linux ARM64 | `e6e4c570251bf5764717610ca2cdbebe8747035db1a1a82c6b5549e04ea6e398` | `7482a7a34895e663214ee7fe030d5c479316012e86942746ad8fdf4e6dec7eef` |

Each target passed on Elixir 1.20.4 with OTP 29.0.6 and Elixir 1.18.4 with
OTP 27.3.4.15. Each consumer compiled the tagged Hex archive locally with
warnings denied, then downloaded the bundle through
`mix smolbox.embedded.install` from an isolated account with Rust off its
path and an empty GitHub CLI configuration. Each installed notice archive
matched the release catalog. The packaged quickstart printed `42` and
`VM cleanup complete`. Each platform exercised both the default tag and
an explicit tag. Apple Silicon had Gatekeeper enabled and passed helper
signature and Hypervisor entitlement checks. Linux guests had working KVM.
An immediate Linux process check caught two helpers still exiting after the
quickstart. The follow-up confirmed no remaining processes, VM rows or
create reservations.
[Live backend qualification](smolvm-1.34.0-qualification.md)
