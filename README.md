# SmolBox

Run Python, JavaScript, and other programs in disposable or retained microVMs from Elixir.

SmolBox is an Elixir client and supervised execution runtime for
[smolvm](https://github.com/smol-machines/smolvm), which runs lightweight virtual
machines on your own hosts. smolvm provides the machines and worker API; SmolBox
tracks commands, results, and cleanup from your application's supervision tree.

Use it when an Elixir application needs to call a Python library, run a JavaScript
processing step, or execute a script in a separate guest environment. You operate
the workers and prepare images containing the languages and dependencies you need.
The default execution API runs one command in its own disposable VM.
`SmolBox.Machines` also manages retained machines that can run successive commands.

## Why use SmolBox?

Executing a command is only part of integrating a worker. Your application also
needs to handle duplicate requests, lost responses, restarts, and leftover VMs.
SmolBox provides that execution lifecycle:

- **Keep one identity for a request.** Submitting the same scoped ID and
  specification returns the existing handle. A different specification under
  that ID is rejected.
- **Track work across application restarts.** A durable store adapter preserves
  execution records so the runtime can resume observation and cleanup. When a
  command may have run but its result was lost, SmolBox records an unknown outcome
  instead of automatically running it again.
- **Manage files and machine lifecycle.** The runtime stages input files, limits
  captured output and file sizes, and tracks cancellation and cleanup separately
  from the command's exit status.

## What execution looks like

This example assumes a supervised runtime named `MyApp.Sandboxes` is already
configured. `python_artifact` is the registered Python image's identity map
(`"id"`, `"sha256"`, `"architecture"`), and `profile` is one of the runtime's
allowed execution profiles. [Getting started](docs/getting-started.md) walks
through the complete worker and runtime setup.

```elixir
alias SmolBox.{Command, ExecutionSpec}

argv = ["python", "-c", "print(6 * 7)"]
{:ok, command} = Command.new(argv, timeout_secs: 10)

{:ok, spec} =
  ExecutionSpec.new(
    scope: "demo",
    id: "answer-001",
    artifact: python_artifact,
    profile: profile,
    command: command
  )

{:ok, handle} = SmolBox.submit(MyApp.Sandboxes, spec)
{:ok, ^handle} = SmolBox.submit(MyApp.Sandboxes, spec)

{:ok, execution} =
  SmolBox.await(MyApp.Sandboxes, handle, 90_000)

%{state: :completed, result: result} = execution
%{exit_code: 0, stdout: stdout} = result

IO.write(stdout)
# Prints: 42
```

The second submission reuses the execution; it does not start another command.
The matches above show a successful run. In your application, handle errors,
nonzero exits, and unknown outcomes explicitly. Cleanup can still be pending when
`await/3` returns, and its wait timeout does not cancel the command. Keep the
runtime supervised and inspect the record with `SmolBox.fetch/3`; see
[result handling and troubleshooting](docs/troubleshooting.md).

If your application already owns machine lifecycle and persistence,
[`SmolBox.Client`](docs/client.md) exposes individual worker operations for
creating machines, executing commands, streaming output, and transferring files.

## Installation and first run

SmolBox **0.1.5** keeps **smolvm 1.16.1** as its default on Linux x86_64 and
macOS Apple Silicon. Checkpoint execution requires this worker version.

**Before using checkpoints:** upgrade every controller sharing a store to 0.1.5.
Checkpoint records use schema v3, which older controllers cannot read. Existing
image executions keep schema v2 and their current behavior. See
[Upgrading to 0.1.5](docs/recovery.md#upgrading-to-0-1-5), including worker selection
when coming from an older release.

**Upgrading from 0.1.2:** first complete the coordinated
[v2 record upgrade](docs/recovery.md#upgrading-to-0-1-3), including the separate
worker version change. Even offline image records now use v2; after those writes,
reverting to 0.1.2 is not a supported rollback.

Add SmolBox to your application's `mix.exs`:

```elixir
{:smolbox, "~> 0.1.5"}
```

Run `mix deps.get`. The [API documentation](https://hexdocs.pm/smolbox/0.1.5/)
includes the guides below. A local checkout can instead be used with
`{:smolbox, path: "../smolbox"}`.

To run the local walkthrough, you need:

- Elixir **1.18 or later**, using a [tested Elixir/OTP pair](docs/compatibility.md).
- A dedicated worker on Linux x86_64 with KVM or macOS Apple Silicon:
  **smolvm 1.16.1** by default, or explicitly configured 1.16.0, 1.14.6 or
  1.14.1 workers.
- The host's `resize2fs` tool for 1.14.6, 1.16.0 and 1.16.1 disk requests below template sizes.
  On macOS, install `e2fsprogs`; see the [runtime prerequisites](docs/compatibility.md#macos-1-14-6-prerequisites).
- A prepared Python image for that worker's architecture, with its SHA-256
  recorded. The guide links to the image preparation commands and host capacity
  requirements.

**Follow [Getting started](docs/getting-started.md)** to configure supervision,
stage a Python file, submit it, read its output file, and confirm cleanup. The
walkthrough uses an in-memory store and needs no database. Applications that need
restart recovery must provide a durable `SmolBox.Store` adapter; a complete
[PostgreSQL host example](https://github.com/hfiguera/smolbox/tree/v0.1.5/examples/durable_host)
is included in the repository.

## Managed persistent machines (unreleased)

`SmolBox.Machines` gives a machine its own durable identity, ownership, resource
reservation, and create/start/stop/delete lifecycle. Run successive commands with
independent execution identities while retaining guest files. With a durable
store, a new controller reconnects to the same machine after an application restart.
Machines remain until explicitly deleted; uncertain work blocks reuse without replay.

See [Managed persistent machines](docs/persistent-machines.md) for the API,
recovery procedures, the required coordinated store upgrade, and a two-process
PostgreSQL walkthrough. This feature is on the development branch and is not in
published 0.1.5. The existing disposable API remains supported.

## Checkpoint execution

SmolBox 0.1.5 can restore an operator-approved idle, offline checkpoint
into a separate disposable machine for each execution. See
[Executing from a checkpoint](docs/checkpoints.md) for approval, examples and
record schema v3 upgrade requirements.

## Current scope

SmolBox has real execution and durable recovery tests on Linux x86_64 and macOS
Apple Silicon with **smolvm 1.14.1, 1.14.6, 1.16.0 and 1.16.1**; results are recorded in [Compatibility](docs/compatibility.md#runtime-selection).
SmolBox 0.1.5 defaults to **1.16.1**; 0.1.3 defaults to **1.16.0** and
0.1.2 to **1.14.6**.
Before adopting the **1.16.1** default with an older worker, explicitly
configure `runtime_version: "1.16.0"`, `"1.14.6"` or `"1.14.1"`, or follow the
[worker upgrade procedure](docs/host-integration.md#upgrading-a-worker).
The package does not upgrade an external worker. A version mismatch prevents
new execution; arbitrary upstream releases and automatic fallback are not accepted.
Since version 0.1.4, SmolBox selects **1.16.1** by default after
[qualification](docs/compatibility.md#smolvm-1-16-1-qualification) and a cleanup change
that separates disposal from preservation. A failed graceful stop can still leave
unknown work retained; see the [recovery rules](docs/recovery.md#preservation-and-disposal).

SmolBox supports explicit outbound hostname/CIDR policies
with smolvm 1.16.0 and 1.16.1. Offline remains the default. See
[Controlled network access](docs/network-access.md) for setup and validation boundaries.

SmolBox relies on smolvm's isolation model for running untrusted code. Your
deployment must protect worker access and configure host resource limits,
networking, and credentials. A subsequent validation campaign tested these
controls and failure recovery in one constrained Linux deployment; see
[Linux deployment validation](docs/resource-qualification.md#subsequent-linux-deployment-validation)
for its results and limits. The walkthrough does not configure that deployment.

The library's supported qualification remains `:development`. Its allocation
settings and admission reservations do not enforce host quotas; unsupported
hard-control options remain rejected. Read
[Deployment boundaries](docs/security.md) when configuring your workers.

Worker installation, runtime image preparation, authentication, and host storage
remain application/operator responsibilities. SmolBox runs programs already
available in the prepared image. TypeScript needs a compiler or runner in that
image; SmolBox does not build or publish user functions.

## Guides

The [engineering blog](https://hfiguera.github.io/smolbox/) has practical articles
about running programs from Elixir and managing their execution lifecycle.

| Guide | What you will learn |
|---|---|
| [Getting started](docs/getting-started.md) | Connect, stage a Python program, submit it, read its result, and finish cleanup |
| [Managed host integration](docs/host-integration.md) | Configure supervision, workers, profiles, storage, and execution specifications |
| [Managed persistent machines](docs/persistent-machines.md) | Retain a machine across commands, recover management, and explicitly dispose of it |
| [Low-level client](docs/client.md) | Create machines, execute commands, stream output, and transfer files |
| [Controlled network access](docs/network-access.md) | Approve outbound destinations while retaining offline defaults |
| [Troubleshooting](docs/troubleshooting.md) | Interpret errors, unknown outcomes, queued work, and pending cleanup |
| [Persistence and recovery](docs/recovery.md) | Use durable storage and recover after controller or worker failures |
| [Telemetry](docs/telemetry.md) | Observe activity and inspect workers without treating notifications as receipts |
| [Deployment boundaries](docs/security.md) | Understand worker isolation, credentials, file boundaries, and operator responsibilities |
| [Resource evidence](docs/resource-qualification.md) | Review the tested Linux deployment controls, historical experiments, and remaining limits |
| [Compatibility](docs/compatibility.md) | Check the tested smolvm, Elixir/OTP, OS, and artifact combinations |

## Contributing

Source: [hfiguera/smolbox](https://github.com/hfiguera/smolbox). Maintainer toolchain
versions are in `.tool-versions`; tested consumer combinations are recorded in
the compatibility guide. From this repository, `mix ci` runs deterministic checks
without contacting a real worker. Generate this site with
`MIX_ENV=dev mix docs --warnings-as-errors`. Live worker tests are a separate opt-in
operation described in the repository's
[CI guide](https://github.com/hfiguera/smolbox/blob/v0.1.5/scripts/ci/README.md).
