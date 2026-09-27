defmodule SmolBox.DurableHost.ManagedBranchDemo do
  @moduledoc "Durable live branches: independent RAM/disks, held release, and explicit dependency retirement."
  alias SmolBox.{Branches, BranchPolicy, BranchSpec, Client, Machines}
  alias SmolBox.DurableHost.{ManagedCheckpointConfig, Store}

  import SmolBox.DurableHost.PersistentSteps,
    only: [lifecycle: 3, wait_machine: 3, shell_command: 5]

  def run(phase) when phase in ["prepare", "verify", "retire", "release-storage", "held"] do
    {:ok, policy} =
      BranchPolicy.new(
        id: "branch-demo",
        resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 8}
      )

    c =
      ManagedCheckpointConfig.start("capture",
        branch_policies: [policy],
        capacity: %{slots: 8, cpus: 8, memory_mb: 8192, disk_gb: 64}
      )

    c = Map.put(c, :branch_policy, policy)

    try do
      execute(phase, c)
    after
      Supervisor.stop(c.runtime)
    end
  end

  defp execute("prepare", c) do
    prepare(c)
    children = Enum.map(["one", "two"], &create_child(c, &1, false))
    emit(c, "prepared", %{children: children, running_source: true})
  end

  defp execute("verify", c) do
    [one, two] = Enum.map(["one", "two"], &child_handle(c, &1))

    for h <- [one, two, c.handle],
        do:
          shell_command(
            c,
            h,
            "read",
            "cat /workspace/disk /dev/shm/ram",
            "disk-statememory-state"
          )

    shell_command(
      c,
      one,
      "change",
      "printf changed > /workspace/disk; printf changed > /dev/shm/ram",
      ""
    )

    for h <- [two, c.handle],
        do:
          shell_command(
            c,
            h,
            "isolation",
            "cat /workspace/disk /dev/shm/ram",
            "disk-statememory-state"
          )

    {:ok, parent} = Machines.inspect(c.runtime, c.handle)
    {:error, _} = Machines.delete(c.runtime, c.handle, parent.version)
    {:ok, _} = lifecycle(c.runtime, one, :stop)
    wait_machine(c.runtime, one, &(&1.state == :stopped and is_nil(&1.operation)))
    start(c, one)
    shell_command(c, one, "disk-after-start", "cat /workspace/disk", "changed")
    Enum.each([one, two], &delete(c, &1))
    {:ok, %{slots: 3}} = Store.usage(c.store, "checkpoint-worker")

    emit(c, "verified", %{
      ram_preserved: true,
      disk_preserved: true,
      independent_copies: true,
      source_unchanged: true,
      child_absence_verified: true,
      backing_allowance_retained: true
    })
  end

  defp execute("retire", c) do
    true = System.get_env("SMOLBOX_BRANCH_QUIESCED") == "true"

    children = children(c)

    for handle <- children do
      {:ok, %{branch: %{state: :retired}}} =
        Branches.retire(c.runtime, handle, quiesced: true)
    end

    delete(c, c.handle)
    {:ok, usage} = Store.usage(c.store, "checkpoint-worker")
    true = usage.slots == length(children) and usage.disk_gb == 8 * length(children)

    emit(c, "retired", %{
      source_absence_verified: true,
      backing_allowance_retained: true,
      history_retained: true
    })
  end

  defp execute("release-storage", c) do
    true = System.get_env("SMOLBOX_BRANCH_BACKING_REMOVED") == "true"

    for handle <- children(c) do
      {:ok, %{branch: %{state: :closed}}} =
        Branches.release_storage(c.runtime, handle, backing_removed: true)
    end

    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(c.store, "checkpoint-worker")
    emit(c, "storage-released", %{reservations_released: true, history_retained: true})
  end

  defp execute("held", c) do
    prepare(c)

    shell_command(
      c,
      c.handle,
      "park",
      "smolvm-branch-ready </dev/null >/tmp/branch-ready.log 2>&1 &",
      ""
    )

    child = create_child(c, "one", true)
    {:ok, m} = Branches.fetch(c.runtime, child)
    {:error, _} = Machines.stop(c.runtime, child, m.version)
    {:ok, _} = Branches.release(c.runtime, child, m.version)
    {:ok, %{branch: %{state: :released}}} = Branches.await(c.runtime, child, 120_000)
    {:ok, _} = Branches.release(c.runtime, child, m.version)

    shell_command(
      c,
      child,
      "released",
      "cat /workspace/disk /dev/shm/ram",
      "disk-statememory-state"
    )

    delete(c, child)

    emit(c, "held-released", %{
      explicit_release: true,
      duplicate_release_deduplicated: true,
      child_absence_verified: true
    })
  end

  defp prepare(c) do
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
  end

  defp create_child(c, suffix, hold) do
    {_, id} = child_handle(c, suffix)
    {:ok, spec} = BranchSpec.new(id: id, policy: c.branch_policy, idle: true, hold: hold)
    {:ok, h} = Branches.create(c.runtime, c.handle, spec)
    {:ok, %{branch: %{state: state}}} = Branches.await(c.runtime, h, 120_000)
    true = state == if(hold, do: :held, else: :ready)
    {:ok, ^h} = Branches.create(c.runtime, c.handle, spec)
    h
  end

  defp children(c) do
    {:ok, parent} = Machines.inspect(c.runtime, c.handle)
    Enum.map(Map.keys(parent.branch_children), &{parent.scope, &1})
  end

  defp child_handle(c, suffix), do: {elem(c.handle, 0), elem(c.handle, 1) <> "-" <> suffix}

  defp start(c, h) do
    {:ok, _} = lifecycle(c.runtime, h, :start)
    wait_machine(c.runtime, h, &(&1.state == :running and is_nil(&1.operation)))
  end

  defp delete(c, h) do
    {:ok, _} = lifecycle(c.runtime, h, :delete)
    m = wait_machine(c.runtime, h, &(&1.state == :deleted))
    {:error, %{category: :not_found}} = Client.inspect_machine(c.client, m.machine_name)
  end

  defp emit(c, phase, fields) do
    {:ok, p} = Machines.inspect(c.runtime, c.handle)
    fields = Map.update(fields, :children, [], &Enum.map(&1, fn {scope, id} -> [scope, id] end))
    IO.puts(Jason.encode!(Map.merge(fields, %{phase: phase, source_name: p.machine_name})))
  end
end
