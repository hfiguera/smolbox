# SmolBox

An independent Elixir library for self-hosted `smolvm serve` workers.

Implementation is in progress. No managed execution API or production isolation
profile is released yet. See [compatibility evidence](docs/compatibility.md).

The current foundation includes validated command and worker configuration,
prepared-machine requests, guest path validation, byte-exact buffered result
decoding, and a bounded SSE parser. SSE output is explicitly lossy UTF-8 in the
pinned upstream release. Immutable execution specifications use keyed fingerprints;
profiles reject unsupported hard controls and file manifests use bounded host
references. These types do not themselves provide durable execution. Transport and managed execution are still being built.

SmolBox will provide low-level worker operations and an explicitly supervised
execution runtime. It will not bundle a database, workflow engine, language
runner, function publishing system, or hosted sandbox service.

Development uses the versions in `.tool-versions`. Run commands from this
directory. `mix ci` runs deterministic checks and must not contact a real worker.
Real-runtime qualification is a separate opt-in operation.
