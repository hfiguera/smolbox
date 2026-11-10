# Supported platforms

SmolBox 0.5.1 defaults to **SmolVM 1.34.0** for both backends. Use the
[Embedded Port quickstart](embedded-quickstart.md) for a local helper or the
[HTTP worker quickstart](getting-started.md) for a separate SmolVM server.

## Elixir and Erlang

The library requires Elixir **1.18 or later**. The repository and primary CI use
**Elixir 1.20.4 / OTP 29.0.6**. Additional CI pairs are Elixir 1.18.4 / OTP 27.3.4.15,
Elixir 1.19.5 / OTP 28.5 and Elixir 1.20.4 / OTP 28.5.
These tested pairs do not establish support for every possible Elixir/OTP pairing.

## Embedded Port hosts

The bundle installer checks the exact `resize2fs` executable from the
[release input catalog](https://github.com/hfiguera/smolbox/blob/v0.5.1/native/release-inputs.json).
Each entry lists the pinned package downloads and the executable path and
SHA-256. Install the matching host tools before running the quickstart.

| Host | Required preparation |
| --- | --- |
| Apple Silicon | A fresh standard account and the Homebrew e2fsprogs 1.47.4 arm64 Tahoe bottle, with `resize2fs` at `/opt/homebrew/opt/e2fsprogs/sbin/resize2fs`. Keep Gatekeeper enabled. |
| Ubuntu 24.04 x86_64 | Read and write access to `/dev/kvm` and the amd64 e2fsprogs `1.47.0-2.4~exp1ubuntu4.1` packages in the catalog, with `resize2fs` at `/sbin/resize2fs`. |
| Ubuntu 24.04 ARM64 | Read and write access to `/dev/kvm` and the arm64 e2fsprogs `1.47.0-2.4~exp1ubuntu4.1` packages in the catalog, with `resize2fs` at `/sbin/resize2fs`. |

All three targets have an offline quickstart. For broader feature, source and
store limits, see [Embedded Port setup and operation](embedded-port.md).

## Worker hosts and versions

| Host | Supported worker path | Required preparation |
| --- | --- | --- |
| Linux x86_64 | Native smolvm with working KVM | Access to `/dev/kvm`, the complete worker distribution, host disk tools and an image for x86_64 |
| macOS Apple Silicon | Native Darwin ARM64 smolvm distribution | Matching agent and VMM libraries, host disk tools and an image for aarch64; a separate account or host for the demo |

The Elixir controller can connect to a worker on a separate host.

The HTTP worker defaults to **smolvm 1.34.0**. Explicitly configured 1.22.0, 1.20.2, 1.19.0,
1.17.0, 1.16.1, 1.16.0, 1.14.6 and 1.14.1 remain selectable under their feature
limits. The worker must report the exact configured version. A mismatch blocks
new work; there is no automatic fallback or admission of arbitrary newer releases.

Use `runtime_version` in `SmolBox.Runtime.WorkerConfig.new/1` to retain an older
worker. Pin checkpoint approvals to the version that captured them as well.
Worker installation and upgrades are separate from the Elixir dependency.

## Validated configurations

SmolBox supports production use on documented configurations. The attested
SmolBox 0.5.1 Embedded Port bundles passed installation, offline execution and
cleanup on all three published targets. Managed HTTP workers on SmolVM 1.34.0
support Linux x86_64 and Apple Silicon. The live campaigns also covered the
following workloads.
[Release validation](https://github.com/hfiguera/smolbox/releases/tag/v0.5.1)
· [Live test configurations and results](https://github.com/hfiguera/smolbox/blob/v0.5.1/docs/evidence/smolvm-1.34.0-qualification.md)

| Host | HTTP worker | Embedded Port |
| --- | --- | --- |
| Linux x86_64 | Runtime and checkpoint recovery with PostgreSQL, held branches, stopped disk growth, persistent volumes, registry warm and export/reimport | Managed terminal I/O and resize, held branches and backing cleanup, checkpoint capture and restore |
| Linux ARM64 | — | Ordinary VM lifecycle and retained files across graceful helper restart |
| Apple Silicon | File transfer, terminals, startup workloads, port policy and checkpoints | Disposable and retained VM lifecycle, terminal I/O and resize, checkpoint capture and restore |

Use a durable store when records must survive controller restarts. The Memory
store is ephemeral. Check the feature guide for its required store capabilities
and host and source limits. Live Embedded Port crash and independent CLI race
qualification remain deferred.
[Persistence and recovery](recovery.md)
· [Embedded Port qualification scope](embedded-port.md#maintainer-qualification)

## Host prerequisites

Install the complete matching smolvm distribution; do not combine an agent or VMM
library from another release. Approve prepared images by digest and architecture.
Provide host capacity for the worker's runtime image, machine disks, temporary
files and caches as well as SmolBox's reservations.

For disk requests below smolvm's bundled templates, supported versions from 1.14.6
onward need working `resize2fs` in the worker environment. Install your Linux
distribution's `e2fsprogs` package, or `brew install e2fsprogs` on macOS. Before
admitting work, verify file persistence through a stop/start cycle on a fresh
machine you own. A successful health response alone does not verify disk
preparation. The [historical prerequisite report](https://github.com/hfiguera/smolbox/blob/v0.5.1/docs/compatibility.md#host-preparation-prerequisites)
records the failures that led to this requirement.

The Linux demo uses a fresh `SMOLVM_DATA_DIR` and separate HTTP and guest rollout
ports. For macOS, follow the separate account or host setup in
[Getting started](getting-started.md#macos-worker-setup); a different port alone
does not isolate worker state. NixOS installation has not been reproduced by the
maintainer's documented worker checks.

## Check the feature you need

Worker admission does not establish that every feature has been tested on every
platform. Follow the individual guide's worker version, store capability, source
and platform restrictions:

| Feature | Guide and important limit |
| --- | --- |
| Disposable execution | [Getting started](getting-started.md); offline execution from an approved image |
| Outbound networking | [Network access](network-access.md); explicit allowlists on supported workers from 1.16.0 onward |
| Retained machines, ports, long commands and terminals | [Persistent machines](persistent-machines.md); extended image features require supported workers from 1.17.0 onward |
| Registry images and saved state | [Images](images-and-registry-artifacts.md), [exports](machine-exports.md), [checkpoints](managed-checkpoints.md) and [branches](managed-branches.md); managed saved-state operations require supported workers from 1.19.0 onward and have separate platform limits |
| Disk growth | [Disk expansion](disk-expansion.md); Linux checks on 1.20.2, 1.22.0 and 1.34.0 |
| Local volumes | [Local volumes](local-volumes.md); Linux 1.20.2, 1.22.0 or 1.34.0, with one exclusive attachment |

Checkpoint restore is not a promise of portability across worker versions,
architectures or hosts. Preserve the original runtime and platform approvals.

Enforce host resource limits and protect worker access separately from SmolBox
admission. [Deployment boundaries](security.md)
