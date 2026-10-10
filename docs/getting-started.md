# Getting started

Run a Python program in a disposable VM, read `42` from its output file, and
wait for the VM to be deleted. You can use the downloadable Livebook or a Mix
application. Both run the same example with SmolBox **0.4.2** and smolvm **1.22.0**.

You need Elixir 1.18 or later and smolvm installed on the same host as the Elixir
runtime. The Linux instructions below require **x86_64 with working KVM**. For
macOS Apple Silicon, see [macOS worker setup](#macos-worker-setup). Check
[Supported platforms](supported-platforms.md#host-prerequisites) if the host is
not ready. SmolBox does not install smolvm.

This is a local demo with an in-memory store. For existing applications, use
[Upgrading SmolBox](upgrading.md); for deployment controls and host
resource limits, see [Deployment boundaries](security.md).

## 1. Install SmolBox

**Livebook:** the [notebook](notebooks/getting-started.livemd) installs SmolBox
with `Mix.install/1`. No Mix project is needed. Run Livebook locally on the worker
host; a hosted Livebook cannot use that host's loopback endpoint or artifact path.

**Mix application:** run `mix new smolbox_demo`, enter that directory, and add
the following to `deps/0` in `mix.exs`. Then run `mix deps.get`.

```elixir
{:smolbox, "~> 0.4.2"}
```

## 2. Prepare one local worker

The demo uses **offline execution** and needs a **dedicated, empty worker**.
SmolBox validates every machine returned by the worker, including machines created
outside SmolBox. Networking enabled without explicit allowlists is unsupported;
other invalid machine observations also reject the whole list. Health and
readiness alone do not check this. See [Controlled network access](network-access.md)
when you want to allow specific destinations later.

### Linux worker setup

Run these commands in **Bash on the worker host**, inside your Nix development
shell if applicable. `smolvm --version` should report `1.22.0`. Use a new directory
for the image, worker state and demo output:

```bash
export SMOLBOX_DEMO_ROOT="$(mktemp -d)"
chmod 700 "$SMOLBOX_DEMO_ROOT"
mkdir -m 700 "$SMOLBOX_DEMO_ROOT/images" "$SMOLBOX_DEMO_ROOT/worker" "$SMOLBOX_DEMO_ROOT/objects"
cd "$SMOLBOX_DEMO_ROOT/images"
export SMOLVM_DATA_DIR="$SMOLBOX_DEMO_ROOT/worker"

smolvm pack create --image python:3.12-alpine --entrypoint /bin/true \
  --cpus 1 --mem 256 --staging-dir ./staging --output ./python

printf 'Demo directory: %s\n' "$SMOLBOX_DEMO_ROOT"
sha256sum "$SMOLBOX_DEMO_ROOT/images/python.smolmachine"
```

Record the printed directory and SHA256 for step 3. Preparation downloads the
Python image; the demo guest later runs without network access. The artifact
must match the host architecture. The profile uses 20 GiB storage and 10 GiB
overlay allocations; allow space for image layers and templates too. For artifact
approval and reproducible production images, see
[Preparing the reference runtimes](client.md#preparing-the-reference-runtimes).

In the **same terminal**, start the demo worker and leave it running:

```bash
env SMOLVM_DATA_DIR="$SMOLBOX_DEMO_ROOT/worker" \
  SMOLVM_GUEST_ROLLOUT_HOST_PORT=19472 \
  SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576 \
  smolvm serve start --listen 127.0.0.1:19471
```

The state directory keeps this worker separate from your existing machines.
The HTTP and guest rollout ports are also separate; if `19471` or `19472` is
already in use, choose unused ports and update the HTTP URL in step 3.

In a **second terminal**, check the inventory:

```sh
curl --fail http://127.0.0.1:19471/api/v1/machines
```

It must return `{"machines":[]}`. If it contains machines or the request fails,
check the worker's startup output and endpoint before continuing. Keep any
existing inventory intact. See
[Machine inventory problems](troubleshooting.md#machine-inventory-problems).

### macOS worker setup

Use a dedicated macOS account or host with no existing smolvm machines. On the
pinned macOS build, `SMOLVM_DATA_DIR` does **not** isolate worker state.

In that account, use the directory and image preparation commands above. Omit the
`export SMOLVM_DATA_DIR` line and replace the `sha256sum` line with:

```sh
shasum -a 256 "$SMOLBOX_DEMO_ROOT/images/python.smolmachine"
```

Then start the worker without the Linux state override:

```sh
SMOLVM_GUEST_ROLLOUT_HOST_PORT=19472 \
  SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576 \
  smolvm serve start --listen 127.0.0.1:19471
```

Check for `{"machines":[]}` with the same curl command before continuing.

## 3. Run the complete example

### In Livebook

[Download the Livebook](notebooks/getting-started.livemd) and import it into your
local Livebook. It includes the worker setup instructions, configuration and all
execution cells. Paste the directory and SHA256 from step 2 into its configuration
cell, check the worker URL, and evaluate all cells. Livebook 0.19.10 with
Elixir 1.20.4/OTP 29.0.6 is the tested notebook environment; see the
[Linux verification record](evidence/getting-started-livebook.json). That run
used published SmolBox 0.4.1; the [0.4.2 package verification](evidence/getting-started-livebook-0.4.2.json)
checks the release candidate separately.

### In a Mix application

In your application's terminal, set the directory printed in step 2 and its
approved digest:

```bash
export SMOLBOX_DEMO_ROOT=/absolute/path/printed/in_step_2
export SMOLBOX_RUNTIME_URL=http://127.0.0.1:19471
export SMOLBOX_RUNTIME_VERSION=1.22.0
export SMOLBOX_PYTHON_ARTIFACT="$SMOLBOX_DEMO_ROOT/images/python.smolmachine"
export SMOLBOX_PYTHON_SHA256=paste_the_sha256_printed_in_step_2
export SMOLBOX_DEMO_DIR="$SMOLBOX_DEMO_ROOT/objects"
unset SMOLBOX_RUNTIME_SOCKET
iex -S mix
```

Save the block below as `smolbox_demo.exs` and run
`Code.require_file("smolbox_demo.exs")` in IEx. If execution fails after the
supervisor starts, keep the session open and inspect it with
[Troubleshooting](troubleshooting.md) before running it again.

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

worker_options = [
  allow_insecure_loopback: true,
  operation_timeout_ms: 60_000,
  receive_timeout_ms: 55_000
]

worker_options =
  case System.get_env("SMOLBOX_RUNTIME_SOCKET") do
    nil -> worker_options
    socket -> Keyword.put(worker_options, :unix_socket, socket)
  end

{:ok, worker} =
  Worker.new("demo-worker", System.fetch_env!("SMOLBOX_RUNTIME_URL"), worker_options)

{:ok, client} = SmolBox.Client.new(worker)
runtime_version = System.get_env("SMOLBOX_RUNTIME_VERSION", "1.22.0")
{:ok, %{version: ^runtime_version}} = SmolBox.Client.health(client)
:ok = SmolBox.Client.readiness(client)
case SmolBox.Client.list(client) do
  {:ok, []} ->
    :ok

  {:ok, _machines} ->
    raise "This demo needs an empty worker. Use the separate worker from step 2."

  {:error, error} ->
    raise "Could not validate the demo worker inventory: #{inspect(error)}. " <>
            "Check the endpoint and use the separate worker from step 2."
end

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
    runtime_version: runtime_version,
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

Expected output is `hello from SmolBox`, followed by `state: :completed`,
`collection: :complete`, `cleanup: :complete`, and `reservation: nil`. The script
also checks that the collected file contains `42`. A second submission of the
same request returns the same handle.

The supervisor stops after cleanup. The in-memory execution records are then
lost, while the demo directory retains the input/output files and Python image.
Stop the demo worker with Ctrl+C when finished. Keep the printed directory until
you have inspected the results; remove only that demo directory when no longer
needed.

## 4. Understand the result

`SmolBox.await/3` returns an execution outcome, which may include a nonzero exit
code. Inspect `record.state`, `record.result`, `record.collection` and
`record.cleanup` separately. Collection or cleanup may remain incomplete even
when the guest command finishes.

An `:expired` error ends the wait; it does not cancel the execution. Use
`SmolBox.fetch/3` to inspect it or `SmolBox.cancel/3` to request cancellation.
See [Troubleshooting](troubleshooting.md) for result handling.

## 5. Move into your application

- Put `SmolBox.child_spec/1` under your application's supervision tree.
- Configure approved artifacts, workers and profiles once in trusted host code.
- Use a durable store and retain the fingerprint key for restart recovery.
- Reuse the same scoped request ID for retries; use a new ID for new work.
- Choose an artifact adapter that suits your storage and retention requirements.

Continue with [Managed host integration](host-integration.md),
[Persistence and recovery](recovery.md), or the
[community workspace](https://github.com/hfiguera/smolbox/tree/main/examples/community_workspace)
for a Phoenix example with terminals, files and PostgreSQL recovery.

For JavaScript, prepare the Node artifact from the client guide and run
`Command.new(["node", "/workspace/main.js"])`. The approved image must supply any
compiler or runner needed for TypeScript.
