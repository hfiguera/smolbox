# Getting started

This walkthrough runs a Python program in a disposable VM, reads its output file,
and waits for cleanup. It uses an in-memory execution store so you can learn the
API without a database. The final section explains what changes in an application
that needs restart recovery.

## 1. Install SmolBox

In an existing Elixir Mix application, add this entry to `deps/0` in `mix.exs`:

```elixir
{:smolbox, "~> 0.1.0"}
```

Run `mix deps.get` to fetch the package from Hex. With a sibling local checkout, use
`{:smolbox, path: "../smolbox"}` instead. Elixir 1.18 and later are accepted by the
package; use one of the tested Elixir/OTP pairs in [Compatibility](compatibility.md).

For a new application, run `mix new smolbox_demo` and `cd smolbox_demo` first.
SmolBox's application starts its ordinary dependencies, but you explicitly start
each managed runtime under supervision.

## 2. Prepare one local worker

Use Linux x86_64 with KVM or macOS Apple Silicon. This walkthrough runs the Elixir
application on the worker host so it can verify the local artifact file. Remote
workers use a different host configuration; see [Managed host integration](host-integration.md).

You need a **dedicated, empty SmolVM 1.14.1 worker** and an approved native Python
artifact with neutral `/bin/true` startup. Follow the
[reference-runtime preparation instructions](client.md#preparing-the-reference-runtimes)
to create `python.smolmachine`, record its SHA-256, and start the private worker
with the 1 MiB file-transfer cap. The package does not install SmolVM or prepare
runtime images for you. Do not attach this ephemeral demo controller to a worker
managed by another runtime or store.

The example uses the measured reference allocation floor: 20 GiB storage,
10 GiB overlay, and 768 MiB VMM overhead per execution. Check available host
capacity and your actual templates before using it. These are allocation and
admission values, not certified host resource quotas. Workers currently have
development qualification; see [Deployment boundaries](security.md).

In your application directory, set these values using the artifact you approved:

```sh
export SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470
export SMOLBOX_PYTHON_ARTIFACT=/absolute/path/to/python.smolmachine
export SMOLBOX_PYTHON_SHA256=replace_with_the_approved_64_character_sha256
export SMOLBOX_DEMO_DIR="$(mktemp -d)"
chmod 700 "$SMOLBOX_DEMO_DIR"
iex -S mix
```

`SMOLBOX_DEMO_DIR` is a new private directory for input/output objects. Keep it
separate from the runtime image and from all guest-accessible directories.

## 3. Run the complete example

Save the following block as `smolbox_demo.exs` in the consuming application, then
run `Code.require_file("smolbox_demo.exs")` in that IEx session. This is the success
path: each match deliberately stops the walkthrough if an assumption fails.
If it fails after runtime startup, keep IEx open, inspect the execution, and use
[Troubleshooting](troubleshooting.md). Do not repeatedly rerun the script or clear
the worker inventory to hide a failure.

```elixir
alias SmolBox.{Command, ExecutionSpec, Files, Profile, Worker}
alias SmolBox.ArtifactStore.Directory
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.Memory

artifact_path = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")
approved_sha256 = System.fetch_env!("SMOLBOX_PYTHON_SHA256")

actual_sha256 =
  artifact_path
  |> File.stream!(65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)

true = actual_sha256 == approved_sha256

{platform, architecture} =
  case :os.type() do
    {:unix, :darwin} -> {:macos, "aarch64"}
    {:unix, :linux} -> {:linux, "x86_64"}
  end

{:ok, worker} =
  Worker.new("demo-worker", System.fetch_env!("SMOLBOX_RUNTIME_URL"),
    allow_insecure_loopback: true
  )

{:ok, client} = SmolBox.Client.new(worker)
{:ok, %{version: "1.14.1"}} = SmolBox.Client.health(client)
:ok = SmolBox.Client.readiness(client)
{:ok, []} = SmolBox.Client.list(client)

{:ok, profile} =
  Profile.new("demo-offline-v1", storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768)

artifact = %{
  "id" => "demo-python-v1",
  "sha256" => approved_sha256,
  "architecture" => architecture,
  "path" => artifact_path
}

{:ok, configured_worker} =
  WorkerConfig.new(
    client: client,
    platform: platform,
    architecture: architecture,
    artifacts: [artifact],
    profiles: [profile],
    allocation_floor: %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768},
    capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 30}
  )

{:ok, objects} = Directory.new(System.fetch_env!("SMOLBOX_DEMO_DIR"))

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Memory, name: SmolBoxDemo.Store},
      {SmolBox,
       name: SmolBoxDemo.Runtime,
       namespace: "sbxdemo",
       mode: :ephemeral,
       store: {Memory, SmolBoxDemo.Store},
       artifact_store: {Directory, objects},
       fingerprint_key: :crypto.strong_rand_bytes(32),
       workers: [configured_worker],
       max_active: 1}
    ],
    strategy: :rest_for_one
  )

scope = "demo"
id = "hello-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
source_ref = "source-" <> id

source = """
from pathlib import Path
Path('/workspace/result.txt').write_text('42\\n')
print('hello from SmolBox')
"""

:ok = Directory.seed(objects, scope, source_ref, source)

{:ok, command} = Command.new(["python", "/workspace/main.py"], timeout_secs: 10)

{:ok, spec} =
  ExecutionSpec.new(
    scope: scope,
    id: id,
    artifact: Map.drop(artifact, ["path"]),
    profile: profile,
    command: command,
    inputs: [
      %{
        "source" => source_ref,
        "path" => "/workspace/main.py",
        "size" => byte_size(source),
        "sha256" => Files.sha256(source),
        "mode" => "runtime_default"
      }
    ],
    outputs: [
      %{
        "destination" => "answer",
        "path" => "/workspace/result.txt",
        "max_bytes" => 1024
      }
    ]
  )

{:ok, handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)
{:ok, ^handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)
{:ok, record} = SmolBox.await(SmolBoxDemo.Runtime, handle, 90_000)
%{state: :completed, result: %{exit_code: 0}, collection: :complete} = record
IO.write(record.result.stdout)
{:ok, "42\n"} = Directory.read_output(objects, handle, "answer", 1024)

# await/3 returns the command/collection outcome before cleanup may finish.
wait_for_cleanup = fn again, deadline ->
  {:ok, current} = SmolBox.fetch(SmolBoxDemo.Runtime, scope, id)

  cond do
    current.cleanup == :complete and current.reservation == nil ->
      current

    System.monotonic_time(:millisecond) >= deadline ->
      raise "Cleanup is still pending. Keep IEx open and inspect the runtime."

    true ->
      Process.sleep(100)
      again.(again, deadline)
  end
end

cleaned =
  wait_for_cleanup.(wait_for_cleanup, System.monotonic_time(:millisecond) + 60_000)

IO.inspect(Map.take(cleaned, [:state, :collection, :cleanup, :reservation]),
  label: "finished"
)

:ok = Supervisor.stop(supervisor)
```

Expected program output is `hello from SmolBox`, followed by a summary containing
`state: :completed`, `collection: :complete`, `cleanup: :complete`, and
`reservation: nil`. The second submission returns the same handle; it does not
create a second execution. The output file is read through the artifact adapter,
not directly from the worker after cleanup.

The demo stops its supervisor only after cleanup and capacity release are
confirmed. Its in-memory execution records are then lost. The private object
directory still contains the demo's input/output objects; remove that specific
directory yourself when you no longer need them.

## 4. Understand the result

`SmolBox.await/3` returning `{:ok, record}` means a stored outcome is available.
It does not mean your program exited zero. Inspect `record.state`,
`record.result.exit_code` when a result exists, `record.collection`, and
`record.cleanup` independently. A nonzero program exit is still an observed result.
An unknown outcome can have `record.result == nil`.

An `:expired` error from `await/3` ends only that wait. The runtime keeps working;
use `SmolBox.fetch/3` to inspect the original identity. `SmolBox.cancel/3` records
cancellation intent, and later observations establish termination and cleanup.
See [Troubleshooting](troubleshooting.md) for concrete result-handling examples.

## 5. Move into your application

- Put `SmolBox.child_spec/1` under your application's supervision tree. Configure
  workers and approved profiles once in trusted host code.
- Replace `SmolBox.Store.Memory` with a durable adapter when executions must
  survive a restart. Keep the store and fingerprint key stable. The randomly
  generated key above is only for this new ephemeral demo.
- Persist an execution ID for each authorized request. Reuse that ID for the
  same submission; use a new ID only for a deliberately authorized new execution.
- Choose an artifact adapter that meets your storage and retention requirements.
  The directory adapter is a small local implementation.

Continue with [Managed host integration](host-integration.md) and
[Persistence and recovery](recovery.md). The repository's
[minimal host](https://github.com/hfiguera/smolbox/tree/v0.1.0/examples/minimal_host)
and [PostgreSQL host](https://github.com/hfiguera/smolbox/tree/v0.1.0/examples/durable_host)
are complete applications; they are source examples, not modules shipped in the
library package.

For JavaScript, prepare and approve the Node artifact from the client guide, stage
a `.js` file, and use `Command.new(["node", "/workspace/main.js"])`. TypeScript
needs a compiler or runner in the approved image; SmolBox does not transpile it.
