defmodule Mix.Tasks.Workspace.Recover do
  @moduledoc false
  use Mix.Task
  alias SmolBox.{Client, Machine, Machines}
  alias SmolBox.DurableHost.Store
  alias Workspace.{Settings, Workspaces}
  @shortdoc "Inspect or explicitly resolve an owned workspace after operator quiescence"

  def run(args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:req)
    {:ok, repo} = Workspace.Repo.start_link()
    {:ok, settings} = Settings.load()
    {:ok, c} = Settings.build(settings)
    handle = Workspaces.handle(settings["workspace_id"])
    {:ok, machine} = Store.machine(c.store, :fetch, [handle])
    execute(args, c, handle, machine)
    Supervisor.stop(repo)
  end

  defp execute(["inspect"], c, _, machine) do
    summary = %{
      id: machine.id,
      state: machine.state,
      worker: machine.worker_id,
      name: machine.machine_name,
      active_execution: machine.active_execution,
      reservation: machine.reservation,
      absence_at_ms: machine.absence_at_ms,
      usage: Store.usage(c.store, "workspace-worker")
    }

    Mix.shell().info(inspect(summary))
  end

  defp execute(["stop-for-drain", "--controllers-stopped"], c, _, machine) do
    # Preserve disks before worker shutdown; this does not resolve uncertainty.
    {:ok, observed} = Client.inspect_machine(c.client, machine.machine_name)
    true = Machine.same_incarnation?(machine.created_machine, observed)
    {:ok, stopped} = Client.stop(c.client, machine.machine_name)

    true =
      stopped.state == :stopped and Machine.same_incarnation?(machine.created_machine, stopped)

    Mix.shell().info(
      "Owned machine stopped. Uncertainty remains. Drain/fence old worker requests before resolution."
    )
  end

  defp execute(["resolve-stopped", "--quiesced"], c, handle, machine) do
    # This flag is an operator assertion, never inferred from VM state or store leases.
    {:ok, observed} = Client.inspect_machine(c.client, machine.machine_name)
    true = Machine.same_incarnation?(machine.created_machine, observed)
    {:ok, stopped} = Client.stop(c.client, machine.machine_name)

    true =
      stopped.state == :stopped and Machine.same_incarnation?(machine.created_machine, stopped)

    {:ok, runtime} = SmolBox.Runtime.start_link(c.options)
    {:ok, current} = Machines.inspect(runtime, handle)
    {:ok, resolved} = Machines.resolve(runtime, handle, current.version, quiesced: true)
    true = resolved.active_execution == nil
    Supervisor.stop(runtime)

    Mix.shell().info(
      "Stopped incarnation verified. Slot resolved; unknown outcomes preserved. Start explicitly in the app."
    )
  end

  defp execute(_, _, _, _),
    do:
      Mix.raise(
        "Use inspect, stop-for-drain --controllers-stopped, or resolve-stopped --quiesced. Read the recovery guide before asserting quiescence."
      )
end
