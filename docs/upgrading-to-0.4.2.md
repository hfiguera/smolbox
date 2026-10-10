# Upgrading to SmolBox 0.4.2

SmolBox 0.4.2 improves machine inventory diagnostics and the first execution
walkthrough. The default worker remains **smolvm 1.22.0** on Linux x86_64 and
macOS Apple Silicon. Worker admission, network policy validation, API shapes,
store callbacks and dependency requirements are unchanged.

## Shared stores and error readers

Unsupported machine network policies now return
`category: :unsupported_network_policy`. A failed machine list retains
`operation: :list` and reports `evidence: :dispatch_uncertain` after the GET
request. `:not_dispatched` is reserved for failures before a request is sent.
These errors remain redacted; they do not include machine names or response bodies.

This release adds **no SQL migration, store capability or codec revision**.
However, readers from 0.4.1 and earlier reject a stored error containing the new
category. Custom error handlers and decoders also need to accept it.

For applications sharing a durable store:

1. Pause new submissions and coordinate active controllers so an upgraded writer
   cannot record the new category while older readers are still running.
2. Update the dependency and deploy every controller, reader and custom decoder:

   ```elixir
   {:smolbox, "~> 0.4.2"}
   ```

   Run `mix deps.update smolbox` and compile your application. Retain the existing
   store, fingerprint key, approved artifacts and explicit worker version pins.
3. Resume submissions after all readers accept the new category. Inventory errors
   still require investigation; a clearer error does not authorize command replay
   or deletion of existing machines.

Once the new category has been persisted, reverting application code alone can
make existing records unreadable. Retain compatible readers when rolling back;
do not erase execution history to hide the compatibility problem.

## First execution

The [Getting Started guide](getting-started.md) now includes image preparation,
a separate Linux worker state directory, distinct HTTP and guest rollout ports,
and an empty inventory check. A different HTTP port alone does not isolate worker
state. On macOS, use the documented separate account or host instead of relying
on `SMOLVM_DATA_DIR`.

The [downloadable Livebook](notebooks/getting-started.livemd) installs 0.4.2 and
checks Python execution, output collection and VM cleanup. Fill in its directory
and approved SHA256 after preparing the image. Existing machines with networking
enabled without explicit allowlists remain unsupported; use a separate demo
worker rather than modifying or deleting another application's machines.

See [Machine inventory problems](troubleshooting.md#machine-inventory-problems)
for diagnostics and the [Linux package verification](evidence/getting-started-livebook-0.4.2.json)
for the tested environment and limits.

## Earlier releases

If upgrading from 0.4.0 or earlier, also follow
[Upgrading to 0.4.1](upgrading-to-0.4.1.md) for the worker default and retained
runtime version compatibility. Applications coming from 0.3.x must first follow
[Upgrading to 0.4.0](upgrading-to-0.4.0.md) for store and adapter changes. The
linked guides describe the additional requirements for 0.2.x and 0.1.x.

Installing SmolBox does not install or upgrade smolvm, migrate its state, or
convert checkpoints. Existing worker and checkpoint pins remain in force.
