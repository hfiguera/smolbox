# Embedded Port quickstart

Run one offline command in a disposable VM, print `42`, and verify that
SmolBox released its reservation. The Runtime starts a local helper and
uses an in-memory store for the demo. The verified bundle contains the
helper, SmolVM 1.34.0 runtime assets and demo image. The example runs without
Rust or a separate SmolVM HTTP server.

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

Run `mix new smolbox_demo`, enter the new directory, and add SmolBox to
`deps/0` in `mix.exs`.

```elixir
{:smolbox, "~> 0.6.0"}
```

Install the dependency and bundle into a new, private directory. The
installer selects the GitHub release tag that matches the dependency version.

```sh
mix deps.get
mix deps.compile
mix smolbox.embedded.install --install-dir "$HOME/smolbox-demo-install"
```

For a staged candidate, use the same command with
`--archive /private/path/to/candidate.tar.gz --sha256 APPROVED_SHA256`.
Obtain the digest separately from the operator who supplied the candidate.
The public route verifies the downloaded archive against the SmolBox release
workflow and tag before unpacking it. The installer leaves the package,
manifest, and approved demo image at the selected location.

The Hex package includes the quickstart script. From your Mix application, run:

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
