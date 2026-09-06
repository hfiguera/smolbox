# SmolBox

An independent Elixir library for self-hosted `smolvm serve` workers.

Implementation is in progress. No managed execution API or production isolation
profile is released yet. See [compatibility evidence](docs/compatibility.md).

SmolBox will provide low-level worker operations and an explicitly supervised
execution runtime. It will not bundle a database, workflow engine, language
runner, function publishing system, or hosted sandbox service.

Development uses the versions in `.tool-versions`. Run commands from this
directory. `mix ci` runs deterministic checks and must not contact a real worker.
Real-runtime qualification is a separate opt-in operation.
