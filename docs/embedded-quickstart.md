# Embedded Port quickstart

Run one offline command in a disposable VM, print `42`, and verify that
SmolBox released its reservation. The Runtime starts a local helper and
uses an in-memory store for the demo. The verified bundle contains the
helper, matching runtime assets and demo image. SmolBox 0.6.1 uses SmolVM
1.35.1. Its stable `v0.6.1` bundles passed all six current/minimum public
installer lanes in fresh standard accounts. Hex remains unpublished. The example runs without Rust or a
separate SmolVM HTTP server.

## Prerequisites

- Elixir 1.18 or later on Apple Silicon, Linux x86_64, or Linux ARM64. Linux
  needs read and write access to a working `/dev/kvm`.
- A dedicated standard account with empty smolvm state. The helper uses the
  SDK's default data paths for that account.
- The exact `resize2fs` listed for your host in
  [Supported platforms](supported-platforms.md#embedded-port-hosts).
  The installer verifies its path and digest.
- `tar`, `curl`, and a GitHub CLI version that supports
  `gh attestation verify`.

## Install and run

Run `mix new smolbox_demo`, enter the new directory, and add the matching Git
dependency to `deps/0` in `mix.exs` while the candidate Hex release stays unpublished.

```elixir
{:smolbox, github: "hfiguera/smolbox", tag: "v0.6.1"}
```

Install the dependency and bundle into a new, private directory. The
installer selects the GitHub release tag that matches the dependency version.

```sh
mix deps.get
mix deps.compile
mix smolbox.embedded.install --tag v0.6.1 --install-dir "$HOME/smolbox-demo-install"
```

The stable 1.35.1 bundles passed
[current/minimum fresh-account checks](evidence/embedded-port-0.6.1-public-installers.json),
including automatic library-version selection and explicit `--tag v0.6.1`.
The RC retains its original bundles and qualification evidence.
Existing Hex users can pin `{:smolbox, "== 0.6.0"}` and its matching 1.34.0
bundles; the Git dependency above selects the new library source.

For another staged candidate, add
`--archive /private/path/to/candidate.tar.gz --sha256 APPROVED_SHA256` with its
explicit tag. Obtain the digest independently from its operator.
The public route verifies the downloaded archive against the SmolBox release
workflow and tag before unpacking it. The installer leaves the package,
manifest, and approved demo image at the selected location.

The dependency includes the quickstart script. From your Mix application, run:

```sh
mix run deps/smolbox/examples/embedded_port/scripts/quickstart.exs \
  --fresh-domain "$HOME/smolbox-demo-install" "$HOME/smolbox-demo-run"
```

From a SmolBox checkout, use the same path without the `deps/smolbox/` prefix.
The run directory must be new. The script enrolls a fresh domain in the
dedicated account and records its identity in the run directory. A successful
run prints `42` and `VM cleanup complete`. If startup or cleanup is uncertain,
preserve the run directory and its SDK state for inspection. See the
[operation guide](embedded-port.md) for retained machines and upgrade procedures.

For a separate SmolVM server, see [Getting started with an HTTP worker](getting-started.md).
