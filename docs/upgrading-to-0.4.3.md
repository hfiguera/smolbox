# Upgrade to 0.4.3

From 0.4.2, update the dependency and restart your controllers using your normal
coordinated deployment procedure. The default worker remains **smolvm 1.22.0**.
This patch adds no SQL migration, codec revision, error category or store
capability. For earlier versions, first account for the intervening requirements
in [Upgrading SmolBox](upgrading.md).

1. Update your dependency, run `mix deps.update smolbox` and compile:

   ```elixir
   {:smolbox, "~> 0.4.3"}
   ```

2. Keep the existing durable store, worker IDs, namespace, fingerprint key,
   artifact approvals and explicit worker and checkpoint version pins. Deploy
   compatible controllers together; stopping observers does not stop their guests.
   Preserve unknown outcomes rather than submitting the commands again.
3. Verify existing records remain readable, new work completes, output collection
   succeeds and cleanup releases its reservation. Cancellation and cleanup now
   have one bounded maintenance task independent of occupied execution slots.
   If you monitor task counts, allow for that task plus the existing scan task;
   `max_active` continues to limit execution tasks.

Branch and checkpoint preflight now reject workers whose reported version or
readiness differs from configuration. If one of those operations stops being
admitted, check the installed worker and readiness before changing configuration;
the patch does not authorize an arbitrary worker upgrade.

## Rollback

This patch introduces no new stored-record format or values relative to 0.4.2.
Reverting to 0.4.2 restores its earlier runtime behavior, including the
cancellation, cleanup, worker preflight and deadline problems addressed here. Keep the same store
and identities, and inspect unresolved work after a coordinated restart.
Rollback to earlier releases still follows their reader and codec restrictions.

Installing the Elixir package does not install smolvm or convert saved machine
state. Use [Upgrading a worker](host-integration.md#upgrading-a-worker) separately
if you intend to change the worker version.
