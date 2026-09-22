defmodule SmolBox.DurableHost.PersistentDemo do
  @moduledoc """
  Two-process persistent-machine walkthrough. Run `prepare`, let that BEAM exit,
  then run `resume` with the same environment and keys. The second process reads
  the retained guest file, stops/starts the VM, reads again, and explicitly deletes.
  """
  alias SmolBox.{Command, ExecutionSpec, Machines, ManagedMachineSpec, Runtime}
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup

  def run(phase) when phase in ["prepare", "resume"] do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _objects} =
      Setup.build(settings, {Store, store}, :durable, SmolBox.PersistentDemo)

    {options, base} = small_profile(options, base)
    {:ok, runtime} = Runtime.start_link(options)
    handle = {"persistent-demo", settings["id"]}

    try do
      execute(phase, runtime, handle, base, store)
    after
      Supervisor.stop(runtime)
    end
  end

  defp execute("prepare", runtime, {scope, id} = handle, base, _store) do
    {:ok, spec} =
      ManagedMachineSpec.new(scope: scope, id: id, artifact: base.artifact, profile: base.profile)

    {:ok, ^handle} = Machines.create(runtime, spec)
    machine = wait_machine(runtime, handle, &(&1.state in [:created, :running]))

    if machine.state == :created do
      {:ok, _} = Machines.start(runtime, handle, machine.version)
      wait_machine(runtime, handle, &(&1.state == :running))
    end

    command(
      runtime,
      handle,
      base,
      "write",
      "from pathlib import Path; Path('/workspace/persistent.txt').write_text('retained'); print('written')",
      "written\n"
    )

    command(runtime, handle, base, "read-before-restart", read_program(), "retained\n")
    {:ok, machine} = Machines.inspect(runtime, handle)

    IO.puts(
      Jason.encode!(%{
        phase: "prepare",
        machine_name: machine.machine_name,
        state: machine.state,
        reservation_retained: machine.reservation != nil
      })
    )
  end

  defp execute("resume", runtime, handle, base, store) do
    {:ok, original} = Machines.inspect(runtime, handle)
    command(runtime, handle, base, "read-after-restart", read_program(), "retained\n")
    {:ok, machine} = Machines.inspect(runtime, handle)
    {:ok, _} = Machines.stop(runtime, handle, machine.version)
    stopped = wait_machine(runtime, handle, &(&1.state == :stopped))
    true = stopped.reservation != nil
    {:ok, _} = Machines.start(runtime, handle, stopped.version)
    restarted = wait_machine(runtime, handle, &(&1.state == :running))
    true = restarted.machine_name == original.machine_name
    command(runtime, handle, base, "read-after-start", read_program(), "retained\n")
    {:ok, machine} = Machines.inspect(runtime, handle)
    {:ok, _} = Machines.delete(runtime, handle, machine.version)
    deleted = wait_machine(runtime, handle, &(&1.state == :deleted))
    {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} = Store.usage(store, deleted.worker_id)

    IO.puts(
      Jason.encode!(%{
        phase: "resume",
        machine_name: deleted.machine_name,
        same_machine: deleted.machine_name == original.machine_name,
        state: deleted.state,
        absence_verified: deleted.absence_at_ms != nil,
        resources_released: deleted.reservation == nil
      })
    )
  end

  defp command(runtime, {scope, id} = handle, base, suffix, program, expected) do
    {:ok, command} = Command.new(["python", "-c", program], timeout_secs: 5)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: scope,
        id: id <> "-" <> suffix,
        artifact: base.artifact,
        profile: base.profile,
        command: command
      )

    {:ok, execution} = Machines.submit(runtime, handle, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: ^expected}}} =
      SmolBox.await(runtime, execution, 90_000)

    wait_machine(runtime, handle, &is_nil(&1.active_execution))
  end

  defp read_program,
    do: "from pathlib import Path; print(Path('/workspace/persistent.txt').read_text())"

  def wait_machine(runtime, handle, predicate, timeout \\ 90_000),
    do: observe(runtime, handle, predicate, System.monotonic_time(:millisecond) + timeout)

  defp observe(runtime, handle, predicate, deadline) do
    {:ok, record} = Machines.inspect(runtime, handle)

    cond do
      predicate.(record) ->
        record

      record.state in [:unknown, :missing, :conflict] ->
        raise "machine requires resolution: #{inspect(record)}"

      System.monotonic_time(:millisecond) >= deadline ->
        raise "machine observation deadline: #{inspect(record)}"

      true ->
        Process.sleep(50)
        observe(runtime, handle, predicate, deadline)
    end
  end

  # This demo requires resize2fs-capable 1.16.1 workers and keeps disk requests
  # small. Operators must qualify these floors for their prepared image.
  defp small_profile(options, base) do
    profile = %{base.profile | id: "persistent-demo-v1", storage_gb: 2, overlay_gb: 2}

    workers =
      Enum.map(options[:workers], fn worker ->
        %{
          worker
          | profiles: [profile],
            allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768},
            capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 4}
        }
      end)

    {Keyword.put(options, :workers, workers), %{base | profile: profile}}
  end
end
