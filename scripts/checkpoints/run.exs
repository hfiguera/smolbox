# Run from the checkout: mix run scripts/checkpoints/run.exs
# Use the dedicated idle fixture from prepare-fixture.sh, never an arbitrary checkpoint.
alias SmolBox.{Checkpoint, Client, Command, ExecutionSpec, Profile, Runtime, Worker}
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.Memory

path = System.fetch_env!("SMOLBOX_CHECKPOINT_PATH")
socket = System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET")
platform = if :os.type() == {:unix, :darwin}, do: :macos, else: :linux
architecture = if platform == :macos, do: "aarch64", else: "x86_64"

digest =
  path
  |> File.stream!(65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)

{:ok, endpoint} = Worker.new("example", "http://localhost", unix_socket: socket)
{:ok, client} = Client.new(endpoint)
{:ok, profile} = Profile.new("idle-fixture")

{:ok, checkpoint} =
  Checkpoint.new(
    runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0"),
    id: "idle",
    sha256: digest,
    architecture: architecture,
    platform: platform,
    path: path,
    profile: profile
  )

{:ok, worker} =
  WorkerConfig.new(
    runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0"),
    client: client,
    platform: platform,
    architecture: architecture,
    artifacts: [],
    checkpoints: [checkpoint],
    profiles: [profile],
    capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2},
    allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
  )

{:ok, store} = Memory.start_link([])

artifacts =
  Path.join(System.tmp_dir!(), "smolbox-checkpoint-demo-#{System.unique_integer([:positive])}")

File.mkdir_p!(artifacts)
File.chmod!(artifacts, 0o700)
{:ok, artifact_store} = SmolBox.ArtifactStore.Directory.new(artifacts)

{:ok, runtime} =
  Runtime.start_link(
    name: SmolBox.CheckpointDemo,
    namespace: "ckdemo",
    mode: :ephemeral,
    store: {Memory, store},
    artifact_store: {SmolBox.ArtifactStore.Directory, artifact_store},
    fingerprint_key: :crypto.strong_rand_bytes(32),
    workers: [worker]
  )

{:ok, command} = Command.new(["/bin/sh", "-c", "cat /dev/shm/smolbox-marker /workspace/baseline"])

{:ok, spec} =
  ExecutionSpec.new(
    scope: "demo",
    id: "read-state",
    artifact: Checkpoint.artifact(checkpoint),
    profile: profile,
    command: command
  )

{:ok, handle} = SmolBox.submit(runtime, spec)

{:ok, %{state: :completed, result: %{exit_code: 0, stdout: output}}} =
  SmolBox.await(runtime, handle, 90_000)

IO.write(output)

wait = fn again, attempts ->
  {:ok, record} = SmolBox.fetch(runtime, "demo", "read-state")

  cond do
    record.cleanup == :complete ->
      :ok

    attempts == 0 ->
      raise "cleanup incomplete; retain runtime and inspect execution"

    true ->
      Process.sleep(50)
      again.(again, attempts - 1)
  end
end

:ok = wait.(wait, 600)
Supervisor.stop(runtime)
GenServer.stop(store)
:ok = File.rmdir(artifacts)
IO.puts("Checkpoint execution completed; cleanup and capacity release verified.")
