# SmolBox

Run commands in self-hosted SmolVM microVMs from Elixir, with tracked execution,
bounded files and output, cancellation, and cleanup.

Use SmolBox when your application needs to execute Python, JavaScript, or another
program installed in an approved runtime image. You operate the SmolVM workers;
SmolBox connects to them. It works independently of any agent or workflow framework.

**Start with [Getting started](docs/getting-started.md)** for installation and a
complete Python example that stages source, runs it, reads an output file, and
waits for cleanup. No PostgreSQL database is needed for that local demonstration.

## Choose an API

| You need | Use |
|---|---|
| Submit work, retain execution identity, observe results, and manage cleanup | `SmolBox` with a supervised runtime |
| Make individual worker operations and manage their lifecycle yourself | `SmolBox.Client` |
| Recover executions after an application restart | The managed runtime with a durable `SmolBox.Store` adapter |

An execution handle is `{scope, execution_id}`. Repeating the same submission
returns the original handle. If a command may have run but its response was lost,
its outcome remains unknown; recovery does not blindly execute it again.

## Install the release candidate

The current candidate is `0.1.0-rc.1`; it has not been published to Hex. For now,
add the tagged source dependency to your application's `mix.exs`:

```elixir
{:smolbox,
 git: "https://github.com/hfiguera/smolbox.git",
 tag: "v0.1.0-rc.1"}
```

Then run `mix deps.get`. Git installation requires repository access. A local
checkout can instead be used with `{:smolbox, path: "../smolbox"}`. See
[Getting started](docs/getting-started.md) for worker and artifact preparation.

## Guides

| Guide | What you will learn |
|---|---|
| [Getting started](docs/getting-started.md) | Connect, stage a Python program, submit it, read its result, and finish cleanup |
| [Managed host integration](docs/host-integration.md) | Configure supervision, workers, profiles, storage, and execution specifications |
| [Low-level client](docs/client.md) | Create machines, execute commands, stream output, and transfer files |
| [Troubleshooting](docs/troubleshooting.md) | Interpret errors, unknown outcomes, queued work, and pending cleanup |
| [Persistence and recovery](docs/recovery.md) | Use durable storage and recover after controller or worker failures |
| [Telemetry](docs/telemetry.md) | Observe activity and inspect workers without treating notifications as receipts |
| [Deployment boundaries](docs/security.md) | Understand worker isolation, credentials, file boundaries, and operator responsibilities |
| [Compatibility](docs/compatibility.md) | Check the tested SmolVM, Elixir/OTP, OS, and artifact combinations |

## Supported scope

The candidate supports the pinned SmolVM **1.14.1** contract. Real execution and
durable recovery have been tested on Linux x86_64 and macOS Apple Silicon.
Prepared images must match the worker architecture; SmolBox does not install
language runtimes, build user functions, or provision workers.

Workers currently use `:development` qualification. Production hostile-workload
isolation and hard host resource limits are outside this release's qualified
scope. See [deployment boundaries](docs/security.md) before choosing a deployment.
Known command exit, output collection, and machine cleanup are separate results.

## Contributing

Source: [hfiguera/smolbox](https://github.com/hfiguera/smolbox). Maintainer toolchain
versions are in `.tool-versions`; tested consumer combinations are recorded in
the compatibility guide. From this repository, `mix ci` runs deterministic checks
without contacting a real worker. Generate this site with
`MIX_ENV=dev mix docs --warnings-as-errors`. Live worker tests are a separate opt-in
operation described in the repository's CI guide.
