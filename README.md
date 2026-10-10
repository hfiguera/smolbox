# SmolBox

Run Python, JavaScript and other programs in disposable or retained Linux VMs
from Elixir.

SmolBox is a client and supervised execution runtime for
[smolvm](https://github.com/smol-machines/smolvm). smolvm runs the machines on your
hosts; SmolBox tracks command identity, results and cleanup under your
application's supervision tree. You install the workers and prepare the images
containing the languages and dependencies your programs need.

## Start here

Add SmolBox to your application's `mix.exs`, then run `mix deps.get`:

```elixir
{:smolbox, "~> 0.4.2"}
```

Follow [Getting started](docs/getting-started.md) for the complete setup: prepare
an image, start a separate worker, run Python, collect `42` from its output file
and confirm VM cleanup. The guide includes a
[downloadable Livebook](https://hexdocs.pm/smolbox/0.4.2/notebooks/getting-started.livemd) and uses an
in-memory store, so you do not need a database for the first run.

The walkthrough needs Elixir 1.18 or later and smolvm **1.22.0** on Linux x86_64
with KVM or macOS Apple Silicon. See [Supported platforms](docs/supported-platforms.md)
for host prerequisites and older worker versions. Workers are installed
separately; adding the Elixir dependency does not install or upgrade smolvm.

For an existing application, start with [Upgrading SmolBox](docs/upgrading.md).
In 0.4.2, every controller and reader sharing a durable store must accept the new
`:unsupported_network_policy` error category before an upgraded writer records it.

## Why use SmolBox?

Executing a command is only part of integrating a worker. Your application also
needs to handle duplicate requests, lost responses, restarts and leftover VMs.

- **Reuse a request's identity.** Submitting the same scoped ID and specification
  returns its existing handle. A different specification under that ID is rejected.
- **Recover after a restart.** A durable store preserves execution records for
  observation and cleanup. A command that may have run remains unknown when its
  result is lost; SmolBox does not automatically run it again.
- **Track results and cleanup separately.** Input staging, output collection,
  cancellation and VM deletion have their own states. Command success does not
  imply that its machine has already been deleted.

## What execution looks like

After the [Getting started](docs/getting-started.md) setup, your application has a
supervised runtime, an approved Python image and an execution profile. With a
runtime named `MyApp.Sandboxes`:

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

The second submission reuses the execution. Here, `python_artifact` is the approved
image identity map (`"id"`, `"sha256"`, `"architecture"`) and `profile` is a
registered `SmolBox.Profile`. Handle errors, nonzero exits and unknown outcomes
in application code. An `await/3` timeout does not cancel the command. Inspect
cleanup with `SmolBox.fetch/3`; see [Troubleshooting](docs/troubleshooting.md).

## Choose your next step

| What you want to do | Guide |
| --- | --- |
| Add supervision, profiles and durable storage | [Host integration](docs/host-integration.md) |
| Keep a machine and its files across commands | [Persistent machines](docs/persistent-machines.md) |
| Manage the lifecycle yourself | [Low-level client](docs/client.md) |
| Use registry images or prepared artifacts | [Images and registry artifacts](docs/images-and-registry-artifacts.md) |
| Run longer commands, background processes or a terminal | [Long commands](docs/long-running-exec.md) · [Terminals](docs/interactive-terminals.md) |
| Transfer files or retain data after machine deletion | [Guest files](docs/guest-files.md) · [Local volumes](docs/local-volumes.md) |
| Reuse prepared disk or memory state | [Exports](docs/machine-exports.md) · [Checkpoints](docs/managed-checkpoints.md) · [Branches](docs/managed-branches.md) |
| Configure networking or expose a guest service | [Network access](docs/network-access.md) · [Port mappings](docs/port-mappings.md) |
| Recover from failures or prepare maintenance | [Recovery](docs/recovery.md) · [Draining](docs/worker-draining.md) |
| Upgrade an existing deployment | [Upgrading SmolBox](docs/upgrading.md) |

The [community workspace app](https://github.com/hfiguera/smolbox/tree/main/examples/community_workspace)
provides a Phoenix walkthrough using its pinned SmolBox 0.3.0 dependency. It includes
persistent machines, commands, a terminal and PostgreSQL recovery. The
[engineering blog](https://hfiguera.github.io/smolbox/) has longer worked examples.

## Deployment and support

SmolBox relies on smolvm for VM isolation. Your deployment controls worker access,
image approval, host resource limits, networking, credentials and storage.
Admission reservations do not enforce host quotas. Offline networking is the
default, and retained machines remain until explicitly deleted. Read
[Deployment boundaries](docs/security.md) before operating workers.

Supported use remains `:development`. [Supported platforms](docs/supported-platforms.md)
describes usable combinations and feature limits. [Testing reports](docs/testing.md)
collects recorded worker checks, performance measurements and historical results,
with their original versions and limits.

## Contributing

Source: [hfiguera/smolbox](https://github.com/hfiguera/smolbox). Toolchain pins are in
`.tool-versions`. Run `mix ci` for deterministic checks without a real worker.
Build the documentation with `MIX_ENV=dev mix docs --warnings-as-errors`, then run
`MIX_ENV=dev mix smolbox.ci.docs` to check local links and fragments.
Live worker checks are a separate operation described in the repository's
[CI guide](https://github.com/hfiguera/smolbox/blob/main/scripts/ci/README.md).
