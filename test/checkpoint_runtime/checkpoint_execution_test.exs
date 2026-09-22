defmodule SmolBox.CheckpointExecutionTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Checkpoint, Client, Command, ExecutionSpec, Files, Profile, Runtime, Worker}
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.{Codec, Memory}

  @moduletag :runtime
  @moduletag timeout: 120_000

  setup do
    path = System.fetch_env!("SMOLBOX_CHECKPOINT_PATH")
    socket = System.fetch_env!("SMOLBOX_CHECKPOINT_SOCKET")
    platform = if :os.type() == {:unix, :darwin}, do: :macos, else: :linux
    architecture = if platform == :macos, do: "aarch64", else: "x86_64"

    {:ok, endpoint} =
      Worker.new("checkpoint-worker", "http://localhost",
        unix_socket: socket,
        operation_timeout_ms: 60_000,
        receive_timeout_ms: 60_000
      )

    {:ok, client} = Client.new(endpoint)
    version = SmolBox.LabCandidate.runtime_version()
    assert {:ok, %{version: ^version}} = Client.health(client)
    {:ok, profile} = Profile.new("idle-checkpoint", preparation_ms: 60_000)

    digest =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, checkpoint} =
      Checkpoint.new(
        runtime_version: version,
        id: "idle",
        path: path,
        sha256: digest,
        architecture: architecture,
        platform: platform,
        profile: profile
      )

    {:ok, worker} =
      WorkerConfig.new(
        runtime_version: version,
        client: client,
        architecture: architecture,
        platform: platform,
        artifacts: [],
        checkpoints: [checkpoint],
        profiles: [profile],
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2}
      )

    store = start_supervised!(Memory)
    objects = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: SmolBox.CheckpointRuntime,
      namespace: "cktest",
      mode: :ephemeral,
      store: {Memory, store},
      fingerprint_key: :binary.copy(<<7>>, 32),
      artifact_store: {SmolBox.TestArtifacts, objects},
      workers: [worker],
      poll_ms: 50,
      lease_ms: 5000
    ]

    runtime = start_supervised!({Runtime, options})

    %{
      runtime: runtime,
      store: store,
      checkpoint: checkpoint,
      profile: profile,
      client: client,
      objects: objects,
      options: options
    }
  end

  test "independent restores preserve RAM and disk, stage inputs, collect files and delete",
       context do
    source = "input\n"
    Agent.update(context.objects, &Map.put(&1, {"checkpoint", "input"}, source))

    for index <- 1..2 do
      {:ok, command} =
        Command.new([
          "/bin/sh",
          "-c",
          "cat /dev/shm/smolbox-marker /workspace/baseline /workspace/input > /workspace/result; echo changed >/dev/shm/smolbox-marker; echo changed >/workspace/baseline; cat /workspace/result"
        ])

      {:ok, spec} =
        ExecutionSpec.new(
          scope: "checkpoint",
          id: "independent-#{index}",
          artifact: Checkpoint.artifact(context.checkpoint),
          profile: context.profile,
          command: command,
          inputs: [
            %{
              "source" => "input",
              "path" => "/workspace/input",
              "sha256" => Files.sha256(source),
              "size" => byte_size(source),
              "mode" => "runtime_default"
            }
          ],
          outputs: [
            %{
              "destination" => "result-#{index}",
              "path" => "/workspace/result",
              "max_bytes" => 256
            }
          ]
        )

      assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
      assert {:ok, ^handle} = SmolBox.submit(context.runtime, spec)
      assert {:ok, record} = SmolBox.await(context.runtime, handle, 90_000)
      assert record.state == :completed and record.result.exit_code == 0
      assert record.result.stdout == "warm\nbaseline\ninput\n"
      assert record.collection == :complete
      assert settled(context.runtime, handle).reservation == nil

      assert {:error, %{category: :not_found}} =
               Client.inspect_machine(context.client, record.machine_name)
    end
  end

  test "controller restart reads checkpoint identity without replaying completed work", context do
    {:ok, command} = Command.new(["/bin/sh", "-c", "cat /dev/shm/smolbox-marker"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "checkpoint",
        id: "restart",
        artifact: Checkpoint.artifact(context.checkpoint),
        profile: context.profile,
        command: command
      )

    assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(context.runtime, handle, 90_000)
    record = settled(context.runtime, handle)
    assert {:ok, bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
    stop_supervised!(Runtime)
    restarted = start_supervised!({Runtime, context.options})
    assert {:ok, ^handle} = SmolBox.submit(restarted, spec)
    assert {:ok, recovered} = SmolBox.await(restarted, handle, 5000)
    assert recovered.machine_name == record.machine_name
    assert recovered.result.stdout == "warm\n"
  end

  test "guest timeout is retained as evidence with observed cleanup", context do
    {:ok, command} = Command.new(["/bin/sh", "-c", "sleep 3"], timeout_secs: 1)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "checkpoint",
        id: "timeout",
        artifact: Checkpoint.artifact(context.checkpoint),
        profile: context.profile,
        command: command
      )

    assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 90_000)
    assert record.state in [:completed, :unknown]

    if record.state == :completed do
      assert record.result.exit_code != 0
      assert settled(context.runtime, handle).reservation == nil
    else
      # Unknown execution must remain retained. Explicitly authorized test teardown
      # uses its saved identity and does not masquerade as managed cleanup.
      assert record.created_machine != nil
      {:ok, observed} = Client.inspect_machine(context.client, record.machine_name)
      assert SmolBox.Machine.same_incarnation?(record.created_machine, observed)
      assert :ok = Client.delete(context.client, record.machine_name)

      assert {:error, %{category: :not_found}} =
               Client.inspect_machine(context.client, record.machine_name)
    end
  end

  defp settled(runtime, {scope, id} = handle, attempts \\ 600) do
    {:ok, record} = SmolBox.fetch(runtime, scope, id)

    cond do
      record.cleanup == :complete ->
        record

      attempts == 0 ->
        flunk("cleanup did not complete: #{inspect(record.cleanup)}")

      true ->
        Process.sleep(50)
        settled(runtime, handle, attempts - 1)
    end
  end
end
