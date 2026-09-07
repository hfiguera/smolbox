# SmolBox

An independent Elixir library for self-hosted `smolvm serve` workers.

Source: [hfiguera/smolbox on GitHub](https://github.com/hfiguera/smolbox).

Implementation is in progress. The low-level client, managed runtime, versioned
store contract, memory adapter, and host-owned Postgres example are implemented.
Managed Python/JavaScript, cancellation and durable controller-restart cases pass
on real Linux and macOS workers. Full resource qualification and release acceptance remain
incomplete; no production isolation profile is certified.

The managed API accepts immutable keyed identities, reserves capacity, stages
bounded files, persists dispatch intent, observes results, collects outputs, and
reconciles cleanup. A lost command response stays unknown; recovery never
silently replays it. Cancellation and cleanup are separate evidence dimensions.
See [host integration](docs/host-integration.md), [recovery](docs/recovery.md),
[telemetry and inspection](docs/telemetry.md),
[deployment boundaries](docs/security.md),
and the current [compatibility evidence](docs/compatibility.md).

```elixir
{:ok, worker} = SmolBox.Worker.new("local", "http://127.0.0.1:19470",
  allow_insecure_loopback: true)
{:ok, client} = SmolBox.Client.new(worker)
{:ok, machines} = SmolBox.Client.list(client)
```

See the [client guide](docs/client.md) for preparation, execution, ownership,
transport limits, and failure semantics.

Development uses the versions in `.tool-versions`. Run commands from this
repository root. `mix ci` runs deterministic checks and must not contact a real worker.
Real-runtime qualification is a separate opt-in operation.
