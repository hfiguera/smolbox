# Upgrade to 0.4.2

From 0.4.1, **upgrade shared readers and custom error decoders before an upgraded
writer records `:unsupported_network_policy`**. The default worker stays
**smolvm 1.22.0**. No SQL migration, store capability or codec revision is added.
For steps from earlier releases, use [Upgrading SmolBox](upgrading.md).

## Shared stores and error readers

1. Pause new submissions and coordinate active controllers so an upgraded writer
   cannot record the new category while older readers are still running.
2. Update the dependency and deploy every controller, reader and custom decoder:

   ```elixir
   {:smolbox, "~> 0.4.2"}
   ```

   Run `mix deps.update smolbox` and compile your application. Retain the existing
   store, fingerprint key, approved artifacts and explicit worker version pins.
   Update handlers that match error categories to accept
   `:unsupported_network_policy`. Machine list failures now retain
   `operation: :list` and report `evidence: :dispatch_uncertain` after the GET.
3. Verify readers can decode the new category, then resume submissions. Existing
   unsupported network policies still need investigation; the diagnostic does
   not permit command replay or deletion of another application's machines.

See [Machine inventory problems](troubleshooting.md#machine-inventory-problems)
for the worker setup and diagnostic procedure. For a local example, follow
[Getting started](getting-started.md), which uses a dedicated empty worker.

## Rollback

Readers from 0.4.1 and earlier reject stored errors containing the new category.
Once it has been persisted, reverting application code alone can make existing
records unreadable. Retain compatible readers when rolling back; do not erase
execution history to force an older decoder to accept it.

Keep worker and checkpoint version pins. Installing this release does not install
smolvm, migrate its state or convert checkpoints.
