# SmolBox

An independent Elixir library for self-hosted `smolvm serve` workers.

Implementation is in progress. No managed execution API or production isolation
profile is released yet. See [compatibility evidence](docs/compatibility.md).

The current foundation includes validated command and worker configuration,
prepared-machine requests, guest path validation, byte-exact buffered result
decoding, and a bounded SSE parser. SSE output is explicitly lossy UTF-8 in the
pinned upstream release. Immutable execution specifications use keyed fingerprints;
profiles reject unsupported hard controls and file manifests use bounded host
references. These types do not themselves provide durable execution. The low-level
HTTP client is implemented and tested against pinned Linux and macOS workers;
managed execution and persistence are still being built.

The [store foundation](docs/recovery.md) now includes atomic acceptance, fenced
claims, capacity reservations, bounded due queries, and an explicitly ephemeral
memory adapter. Database-backed recovery remains pending.

```elixir
{:ok, worker} = SmolBox.Worker.new("local", "http://127.0.0.1:19470",
  allow_insecure_loopback: true)
{:ok, client} = SmolBox.Client.new(worker)
{:ok, machines} = SmolBox.Client.list(client)
```

See the [client guide](docs/client.md) for preparation, execution, ownership,
transport limits, and failure semantics.

SmolBox will provide low-level worker operations and an explicitly supervised
execution runtime. It will not bundle a database, workflow engine, language
runner, function publishing system, or hosted sandbox service.

Development uses the versions in `.tool-versions`. Run commands from this
directory. `mix ci` runs deterministic checks and must not contact a real worker.
Real-runtime qualification is a separate opt-in operation.
