# SmolBox

Run Python, JavaScript and other programs in disposable or retained Linux VMs
from Elixir.

SmolBox is a client and supervised execution runtime for
[smolvm](https://github.com/smol-machines/smolvm). smolvm runs the machines on your
hosts; SmolBox tracks command identity, results and cleanup under your
application's supervision tree. You install the workers and prepare the images
containing the languages and dependencies your programs need.

## Start here

You need Elixir 1.18 or later and smolvm **1.22.0** on Linux x86_64 with KVM
or macOS Apple Silicon. Worker installation is included in the walkthrough; the
Elixir dependency does not install smolvm.

Choose one path to your first execution:

- **Livebook:** [download the notebook](docs/notebooks/getting-started.livemd),
  import it into a local Livebook and follow its setup instructions. No Mix project
  or database is needed.
- **Mix application:** follow [Getting started](docs/getting-started.md) to install
  the dependencies, prepare an image, start a separate worker, run Python and
  confirm output collection and VM cleanup.

See [Supported platforms](docs/supported-platforms.md) for host prerequisites.
For an existing application, use [Upgrading SmolBox](docs/upgrading.md).

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
supervised runtime, an approved Python image and an execution profile. With
`SmolBoxDemo.Runtime` running and `artifact` and `profile` from setup, submitting
a command looks like this:

```elixir
alias SmolBox.{Command, ExecutionSpec}

argv = ["python", "-c", "print(6 * 7)"]
{:ok, command} = Command.new(argv, timeout_secs: 10)

{:ok, spec} =
  ExecutionSpec.new(
    scope: "demo",
    id: "answer-001",
    artifact: Map.drop(artifact, ["path"]),
    profile: profile,
    command: command
  )

{:ok, handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)
{:ok, ^handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)

{:ok, execution} =
  SmolBox.await(SmolBoxDemo.Runtime, handle, 90_000)

%{state: :completed, result: result} = execution
%{exit_code: 0, stdout: stdout} = result

IO.write(stdout)
# Prints: 42
```

The second submission reuses the execution. The specification uses the image identity from
`artifact` and the registered `profile` created during setup. Handle errors, nonzero exits and unknown outcomes
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
