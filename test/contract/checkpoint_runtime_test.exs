defmodule SmolBox.CheckpointRuntimeTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Checkpoint, Error, ManagedPeer, RuntimeFixture}
  alias SmolBox.Runtime.WorkerConfig

  test "approved checkpoint reuses identity, collects outputs and verifies disposal" do
    context = RuntimeFixture.start(__MODULE__, checkpoint: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, ^handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :completed and record.collection == :complete
    assert wait_cleanup(context.runtime, handle).reservation == nil
    assert [_] = ManagedPeer.snapshot(context.peer).commands
    assert ManagedPeer.snapshot(context.peer).machines == %{}
  end

  test "approval is bound to profile, platform, runtime, digest and source kind" do
    context = RuntimeFixture.start(__MODULE__, checkpoint: true)
    [worker] = context.options[:workers]
    [checkpoint] = worker.checkpoints
    assert WorkerConfig.supports?(worker, context.spec)

    for spec <- [
          %{context.spec | profile: %{context.spec.profile | id: "different"}},
          %{
            context.spec
            | artifact: Map.put(context.spec.artifact, "sha256", String.duplicate("0", 64))
          },
          %{context.spec | artifact: Map.delete(context.spec.artifact, "kind")}
        ] do
      refute WorkerConfig.supports?(worker, spec)

      assert {:error, %Error{category: :unsupported_capability}} =
               SmolBox.submit(context.runtime, spec)
    end

    for change <- [
          %{runtime_version: "1.16.0"},
          %{platform: :macos},
          %{checkpoints: [checkpoint, checkpoint]},
          %{checkpoints: [%{checkpoint | runtime_version: "1.16.0"}]}
        ] do
      assert {:error, _} = WorkerConfig.validate(struct(worker, change))
    end

    assert Checkpoint.artifact(checkpoint) == context.spec.artifact

    for version <- ["1.16.1", "1.17.0"] do
      approved = %{checkpoint | runtime_version: version}
      matched = %{worker | runtime_version: version, checkpoints: [approved]}
      assert :ok = WorkerConfig.validate(matched)
      assert WorkerConfig.supports?(matched, context.spec)

      other = if version == "1.16.1", do: "1.17.0", else: "1.16.1"
      assert {:error, _} = WorkerConfig.validate(%{matched | runtime_version: other})
    end
  end

  test "lost creation response never starts, replays or deletes a machine without evidence" do
    context = RuntimeFixture.start(__MODULE__, checkpoint: true, create_lost: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :failed
    assert record.created_machine == nil
    Process.sleep(100)
    state = ManagedPeer.snapshot(context.peer)
    assert Enum.count(state.operations, &(&1 == {"POST", "/api/v1/machines"})) == 1
    assert state.commands == []

    refute Enum.any?(state.operations, fn {method, path} ->
             method == "DELETE" or String.ends_with?(path, "/start")
           end)

    assert map_size(state.machines) == 1
  end

  test "captured network or allocation mismatch prevents starting restored work" do
    for changes <- [
          %{"network" => true},
          %{"memoryMb" => 512},
          %{"storageGb" => 2},
          %{"branchable" => false},
          %{"state" => "running"}
        ] do
      context = RuntimeFixture.start(__MODULE__, checkpoint: true, created_allocations: changes)
      assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
      assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
      assert record.state == :failed and record.created_machine == nil

      refute Enum.any?(ManagedPeer.snapshot(context.peer).operations, fn {_method, path} ->
               String.ends_with?(path, "/start")
             end)

      stop_supervised!(SmolBox.Runtime)
      stop_supervised!(SmolBox.Store.Memory)
      stop_supervised!(Agent)
    end
  end

  defp wait_cleanup(runtime, handle, attempts \\ 100) do
    {:ok, record} = SmolBox.fetch(runtime, elem(handle, 0), elem(handle, 1))

    if record.cleanup == :complete or attempts == 0,
      do: record,
      else:
        (
          Process.sleep(20)
          wait_cleanup(runtime, handle, attempts - 1)
        )
  end
end
