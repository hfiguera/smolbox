# Try the Embedded Port quickstart

This preview runs one offline command in a disposable VM, prints `42`, and
checks that SmolBox released the reservation. The Runtime starts the local
helper. The demo uses an in-memory store.

The prebuilt install path is under release qualification. Use the
[HTTP getting-started guide](getting-started.md) with the currently published
Hex release. A maintainer can provide a privately staged candidate and its
independently approved SHA-256 for the preview.

## Prerequisites

- Elixir 1.18 or later on Apple Silicon, Linux x86_64, or Linux ARM64. Linux
  needs read and write access to a working `/dev/kvm`.
- A dedicated standard account with empty smolvm state. The helper uses the
  SDK's default data paths for that account.
- The exact `resize2fs` recorded by the bundle. The installer checks its path
  and digest. This is a current constraint on which hosts a prebuilt bundle
  can support. See [Embedded Port host preparation](embedded-port.md#package-and-host-preparation).
- `tar`. The public download route also uses `curl` and a GitHub CLI version
  that supports `gh attestation verify`.

## Install and run

In a Mix application with SmolBox installed, run `mix deps.get` and
`mix deps.compile`. After publication, use the matching version tag and a
new, private install directory.

```sh
mix smolbox.embedded.install --tag "vVERSION" --install-dir "$HOME/smolbox-demo-install"
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
