# Supported platforms

Use this page to choose an Elixir toolchain, worker host and smolvm version for
SmolBox 0.4.2. To install smolvm, follow
[Install smolvm 1.22.0](getting-started.md#install-smolvm-1-22-0), then continue
with the complete [Getting started](getting-started.md) example. For an existing deployment, follow
[Upgrading SmolBox](upgrading.md).

## Elixir and Erlang

The library requires Elixir **1.18 or later**. The repository and primary CI use
**Elixir 1.20.4 / OTP 29.0.6**. Additional CI pairs are Elixir 1.18.4 / OTP 27.3.4.15,
Elixir 1.19.5 / OTP 28.5 and Elixir 1.20.4 / OTP 28.5.
These tested pairs do not establish support for every possible Elixir/OTP pairing.

## Worker hosts and versions

| Host | Supported worker path | Required preparation |
| --- | --- | --- |
| Linux x86_64 | Native smolvm with working KVM | Access to `/dev/kvm`, the complete worker distribution, host disk tools and an image for x86_64 |
| macOS Apple Silicon | Native Darwin ARM64 smolvm distribution | Matching agent and VMM libraries, host disk tools and an image for aarch64; a separate account or host for the demo |

Linux ARM64, Windows workers and Intel macOS are outside the tested worker support.
The controller talks to a worker API; this table describes worker hosts, not a
requirement that every controller run on the same host as its worker.

The default worker is **smolvm 1.22.0**. Explicitly configured 1.20.2, 1.19.0,
1.17.0, 1.16.1, 1.16.0, 1.14.6 and 1.14.1 remain selectable under their feature
limits. The worker must report the exact configured version. A mismatch blocks
new work; there is no automatic fallback or admission of arbitrary newer releases.

Use `runtime_version` in `SmolBox.Runtime.WorkerConfig.new/1` to retain an older
worker. Pin checkpoint approvals to the version that captured them as well.
Worker installation and upgrades are separate from the Elixir dependency.

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
preparation. The [historical prerequisite report](compatibility.md#host-preparation-prerequisites)
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
| Disk growth | [Disk expansion](disk-expansion.md); Linux checks on 1.20.2 and 1.22.0, with no macOS growth campaign |
| Local volumes | [Local volumes](local-volumes.md); Linux 1.20.2 or 1.22.0, one exclusive attachment and no worker migration |

Checkpoint restore is not a promise of portability across worker versions,
architectures or hosts. Preserve the original runtime and platform approvals.

Supported use remains `:development`. Your deployment must enforce host resource
limits and protect worker access; admission reservations are not host quotas.
Read [Deployment boundaries](security.md) for those responsibilities and
[Testing reports](testing.md) for recorded checks and their limits.
