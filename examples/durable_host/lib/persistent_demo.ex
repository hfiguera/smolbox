defmodule SmolBox.DurableHost.PersistentDemo do
  @moduledoc """
  Two-process persistent-machine walkthrough. Run `prepare`, let that BEAM exit,
  then run `resume` with the same environment and keys. The second process reads
  the retained guest file, stops/starts the VM, reads again, and explicitly deletes.
  """
  alias SmolBox.{Machines, ManagedMachineSpec, Runtime}
  import SmolBox.DurableHost.PersistentSteps
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
      {:ok, _} = lifecycle(runtime, handle, :start)
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
    {:ok, _} = lifecycle(runtime, handle, :stop)
    stopped = wait_machine(runtime, handle, &(&1.state == :stopped))
    true = stopped.reservation != nil
    {:ok, _} = lifecycle(runtime, handle, :start)
    restarted = wait_machine(runtime, handle, &(&1.state == :running))
    true = restarted.machine_name == original.machine_name
    command(runtime, handle, base, "read-after-start", read_program(), "retained\n")
    {:ok, _} = lifecycle(runtime, handle, :delete)
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

  defp read_program,
    do: "from pathlib import Path; print(Path('/workspace/persistent.txt').read_text())"
end
