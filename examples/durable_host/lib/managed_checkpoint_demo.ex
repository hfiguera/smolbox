defmodule SmolBox.DurableHost.ManagedCheckpointDemo do
  @moduledoc "Durable capture, operator confirmation, independent restores, and explicit artifact release."
  alias SmolBox.{CheckpointCaptureSpec, Checkpoints, Client, Machines}
  alias SmolBox.DurableHost.{ManagedCheckpointConfig, Store}
  alias SmolBox.Example.Setup

  import SmolBox.DurableHost.PersistentSteps,
    only: [lifecycle: 3, wait_machine: 3, shell_command: 5]

  def run(phase) when phase in ["capture", "confirm", "restore", "release"] do
    c = ManagedCheckpointConfig.start(phase)

    try do
      execute(phase, c)
    after
      Supervisor.stop(c.runtime)
    end
  end

  defp execute("capture", c) do
    {:ok, handle} = Machines.create(c.runtime, c.spec)
    wait_machine(c.runtime, handle, &(&1.state == :created))
    start(c, handle)

    shell_command(
      c,
      handle,
      "prepare",
      "printf disk-state > /workspace/disk; printf memory-state > /dev/shm/ram",
      ""
    )

    shell_command(
      c,
      handle,
      "verify",
      "cat /workspace/disk /dev/shm/ram",
      "disk-statememory-state"
    )

    {:ok, spec} = CheckpointCaptureSpec.new(id: "prepared", policy: c.policy, idle: true)
    {:ok, handle} = Checkpoints.capture(c.runtime, handle, spec)
    {:ok, %{state: :captured, result: r}} = Checkpoints.await(c.runtime, handle, 900_000)

    IO.puts(
      Jason.encode!(%{
        phase: "captured",
        sha256: r.sha256,
        size_bytes: r.size_bytes,
        path: r.path,
        quiescence_confirmation_required: true
      })
    )
  end

  defp execute("confirm", c) do
    true = System.get_env("SMOLBOX_CAPTURE_QUIESCED") == "true"
    {:ok, m} = Machines.inspect(c.runtime, c.handle)

    {:ok, %{state: :completed}} =
      Checkpoints.resolve(c.runtime, c.capture, m.version, quiesced: true)

    {:ok, %{slots: 1, disk_gb: 3}} = Store.usage(c.store, "checkpoint-worker")

    IO.puts(
      Jason.encode!(%{phase: "confirmed", source_retained: true, checkpoint_disk_retained: true})
    )
  end

  defp execute("restore", c) do
    handles =
      Enum.map(["copy-one", "copy-two"], fn suffix ->
        {:ok, handle} =
          Checkpoints.restore(c.runtime, c.capture, c.approval,
            scope: elem(c.handle, 0),
            id: elem(c.handle, 1) <> "-" <> suffix
          )

        wait_machine(c.runtime, handle, &(&1.state == :created))
        start(c, handle)

        shell_command(
          c,
          handle,
          "verify",
          "cat /workspace/disk /dev/shm/ram",
          "disk-statememory-state"
        )

        handle
      end)

    shell_command(
      c,
      hd(handles),
      "modify",
      "printf changed > /workspace/disk; printf changed > /dev/shm/ram",
      ""
    )

    shell_command(
      c,
      List.last(handles),
      "unchanged",
      "cat /workspace/disk /dev/shm/ram",
      "disk-statememory-state"
    )

    shell_command(
      c,
      c.handle,
      "unchanged",
      "cat /workspace/disk /dev/shm/ram",
      "disk-statememory-state"
    )

    Enum.each([c.handle | handles], fn handle ->
      {:ok, _} = lifecycle(c.runtime, handle, :delete)
      m = wait_machine(c.runtime, handle, &(&1.state == :deleted))
      {:error, %{category: :not_found}} = Client.inspect_machine(c.client, m.machine_name)
    end)

    {:ok, %{slots: 0, disk_gb: 1}} = Store.usage(c.store, "checkpoint-worker")
    {:ok, %{result: result}} = Checkpoints.fetch(c.runtime, c.capture)
    true = Setup.digest_file(result.path) == result.sha256

    IO.puts(
      Jason.encode!(%{
        phase: "restored",
        ram_preserved: true,
        disk_preserved: true,
        independent_copies: true,
        source_unchanged: true,
        machines_absent: true,
        artifact_retained: true
      })
    )
  end

  defp execute("release", c) do
    true = System.get_env("SMOLBOX_REMOVE_CAPTURE") == "true"
    {:ok, %{state: :completed, result: result}} = Checkpoints.fetch(c.runtime, c.capture)
    true = Setup.digest_file(result.path) == result.sha256
    File.rm!(result.path)
    {:ok, _} = Checkpoints.release(c.runtime, c.capture, artifacts_removed: true)
    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(c.store, "checkpoint-worker")

    IO.puts(
      Jason.encode!(%{phase: "released", history_retained: true, reservations_released: true})
    )
  end

  defp start(c, handle) do
    {:ok, _} = lifecycle(c.runtime, handle, :start)
    wait_machine(c.runtime, handle, &(&1.state == :running and is_nil(&1.operation)))
  end
end
