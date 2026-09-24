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
`SmolBox.Machines` also manages retained machines that can run successive commands
and expose TCP services through fixed [worker-host port mappings](docs/port-mappings.md).
[Startup workloads and console diagnostics](docs/workloads.md) add immutable
entrypoint, command, environment and working directory on managed image machines.
Console snapshots and bounded streaming aid boot diagnosis; application stdout/stderr
and automatic restart policies remain unsupported by qualified upstream behavior.

[Interactive terminal sessions](docs/interactive-terminals.md) add bounded input/output,
resizing and durable exit-or-uncertainty tracking on retained machines.

[Long-running commands and background launch](docs/long-running-exec.md) support
longer builds and persistent services, with explicit budgets and typed launch evidence.

[Guest paths and larger files](docs/guest-files.md) authorize project and home
directories and buffered files up to 16 MiB. Defaults remain `/workspace` and
1 MiB. Policies persist through controller recovery and apply to ordinary command
working directories too.

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

SmolBox **0.2.0** defaults to **smolvm 1.17.0** on Linux x86_64 and macOS
Apple Silicon, following [real-worker qualification](docs/compatibility.md#smolvm-1-17-0-qualification).
It adds retained machines, services, terminals, startup configuration and larger
file transfers while preserving the existing disposable execution API.

**Upgrading from 0.1.x requires coordination.** Upgrade shared controllers and
store adapters together, apply the example's machine/port migrations if using it,
and upgrade workers separately or explicitly pin their installed versions.
New record formats and retained tombstones constrain rollback. Start with
[Upgrading to 0.2.0](docs/upgrading-to-0.2.0.md).

Add SmolBox to your application's `mix.exs`:

```elixir
{:smolbox, "~> 0.2.0"}
```

Run `mix deps.get`. The [API documentation](https://hexdocs.pm/smolbox/0.2.0/)
includes the guides below. A local checkout can instead be used with
`{:smolbox, path: "../smolbox"}`.

To run the local walkthrough, you need:

- Elixir **1.18 or later**, using a [tested Elixir/OTP pair](docs/compatibility.md).
- A dedicated worker on Linux x86_64 with KVM or macOS Apple Silicon:
  **smolvm 1.17.0** by default, or explicitly configured 1.16.1, 1.16.0, 1.14.6 or
  1.14.1 workers.
- The host's `resize2fs` tool for 1.14.6, 1.16.0, 1.16.1 and 1.17.0 disk requests below template sizes.
  On macOS, install `e2fsprogs`; see the [runtime prerequisites](docs/compatibility.md#macos-1-14-6-prerequisites).
- A prepared Python image for that worker's architecture, with its SHA-256
  recorded. The guide links to the image preparation commands and host capacity
  requirements.

**Follow [Getting started](docs/getting-started.md)** to configure supervision,
stage a Python file, submit it, read its output file, and confirm cleanup. The
walkthrough uses an in-memory store and needs no database. Applications that need
restart recovery must provide a durable `SmolBox.Store` adapter; a complete
[PostgreSQL host example](https://github.com/hfiguera/smolbox/tree/v0.2.0/examples/durable_host)
is included in the repository.

## Managed persistent machines

`SmolBox.Machines` gives a machine its own durable identity, ownership, resource
reservation, and create/start/stop/delete lifecycle. Run successive commands with
independent execution identities while retaining guest files. With a durable
store, a new controller reconnects to the same machine after an application restart.
Machines remain until explicitly deleted; uncertain work blocks reuse without replay.

See [Managed persistent machines](docs/persistent-machines.md) for the API,
recovery procedures, the required coordinated store upgrade, and a two-process
PostgreSQL walkthrough. The existing disposable API remains supported.

## Checkpoint execution

SmolBox can restore an operator-approved idle, offline checkpoint
into a separate disposable machine for each execution. See
[Executing from a checkpoint](docs/checkpoints.md) for approval, examples and
record schema v3 upgrade requirements.

## Current scope

SmolBox has real execution and durable recovery tests on Linux x86_64 and macOS
Apple Silicon with **smolvm 1.14.1, 1.14.6, 1.16.0, 1.16.1 and 1.17.0**; results are recorded in [Compatibility](docs/compatibility.md#runtime-selection).
SmolBox 0.2.0 defaults to **1.17.0**, while 0.1.4–0.1.5 default to **1.16.1**; 0.1.3 defaults to **1.16.0** and
0.1.2 to **1.14.6**.
Before adopting 0.2.0's **1.17.0** default with an older worker, explicitly
configure `runtime_version: "1.16.1"`, `"1.16.0"`, `"1.14.6"` or `"1.14.1"`, or follow the
[worker upgrade procedure](docs/host-integration.md#upgrading-a-worker).
The package does not upgrade an external worker. A version mismatch prevents
new execution; arbitrary upstream releases and automatic fallback are not accepted.
Published versions 0.1.4 and 0.1.5 select **1.16.1** by default after
[qualification](docs/compatibility.md#smolvm-1-16-1-qualification) and a cleanup change
that separates disposal from preservation. A failed graceful stop can still leave
unknown work retained; see the [recovery rules](docs/recovery.md#preservation-and-disposal).

SmolBox supports explicit outbound hostname/CIDR policies
with smolvm 1.16.0, 1.16.1 and 1.17.0. Offline remains the default. See
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
[CI guide](https://github.com/hfiguera/smolbox/blob/v0.2.0/scripts/ci/README.md).
