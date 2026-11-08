# Embedded Port example

This source checkout supports public development Runtime admission. Read
[the setup guide](../../docs/embedded-port.md) first. The Elixir dependency alone
includes no native package and performs no downloads or Rust compilation.

Approve the helper package and offline artifact, then set:

- `SMOLBOX_EMBEDDED_PACKAGE`: absolute private package directory.
- `SMOLBOX_EMBEDDED_MANIFEST_SHA256`: approved SHA-256 of `package.json`.
- `SMOLBOX_EMBEDDED_DOMAIN_JSON`: private domain file with stable `target_id` and
  `generation` (32 lowercase hexadecimal characters).
- `SMOLBOX_EMBEDDED_ARTIFACT`: approved absolute `.smolmachine` path.
- `SMOLBOX_EMBEDDED_ARTIFACT_SHA256`: approved artifact SHA-256.

For a new dedicated SDK account, create the domain file once with mode `0600`,
choose a stable target ID and a random generation (`:crypto.strong_rand_bytes(16)`
encoded as lowercase hex). Set `SMOLBOX_EMBEDDED_INITIALIZE=true` only for explicit
first enrollment. An existing domain must use its original generation; do not
rotate it or run another SDK writer concurrently. Initialization defaults to false.

Validate configuration without launching the helper:

```sh
MIX_ENV=prod mix run examples/embedded_port/config.example.exs
```

Run the complete public lifecycle with a **new** private run directory:

```sh
export SMOLBOX_EMBEDDED_RUN_DIRECTORY=/absolute/new-run-directory
MIX_ENV=prod mix run examples/embedded_port/scripts/run.exs
```

The example creates and deletes its disposable and retained machines. It verifies
Exit 7, transfers 1,048,593 binary bytes, drains new assignments while retained
commands continue, normally restarts only the Runtime, resumes with the control
version, and checks that all owned reservations are released. A successful run
writes `evidence.json`; receipt-bearing `private-records-*.json` files stay private.
Failures preserve those records before normal shutdown. Never fabricate receipts
from SDK inventory or replay an uncertain command.

The default store is **ephemeral Memory**. Full BEAM/store loss can strand VMs;
private forensic files are not a store backup or restore API. For a durable host,
use `SmolBox.Example.EmbeddedPort.run/3` with `store: {adapter, context}`,
`mode: :durable` and a stable `fingerprint_key`; start that store before the example.
The example can also accept `http_workers: [...]` to exercise separately configured
HTTP workers while the native target drains. These workers require separate SDK
accounts or domains from the embedded helper.

Live process interruption testing and native distribution signing/source delivery
remain outside this development example. Rustler and Kubernetes are not implemented.
