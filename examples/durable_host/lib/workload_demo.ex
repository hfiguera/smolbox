defmodule SmolBox.DurableHost.WorkloadDemo do
  @moduledoc "Immutable startup workload and console diagnostics across separate controllers."
  alias SmolBox.{Machines, ManagedMachineSpec, Runtime, Workload}

  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  import SmolBox.DurableHost.PersistentSteps

  @program ~S"""
  import os, pathlib, time
  root = pathlib.Path('/workspace')
  root.mkdir(exist_ok=True)
  with (root / 'workload-starts').open('a') as f:
      f.write(os.environ['APP_MODE'] + ':' + os.getcwd() + '\n')
      f.flush()
      os.fsync(f.fileno())
  print('-'.join(['application', 'stdout', 'is', 'not', 'console']), flush=True)
  time.sleep(600)
  """

  def run(phase) when phase in ["prepare", "resume", "delete"] do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _objects} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)
    {:ok, runtime} = Runtime.start_link(options)

    c = %{
      runtime: runtime,
      base: base,
      handle: {"workload-demo", settings["id"]},
      store: store,
      client: hd(options[:workers]).client
    }

    try do
      execute(phase, c)
    after
      Supervisor.stop(runtime)
    end
  end

  defp execute("prepare", c) do
    {:ok, workload} =
      Workload.new(
        entrypoint: ["python"],
        cmd: ["-c", @program],
        env: [{"APP_MODE", "configured"}],
        workdir: "/"
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1),
        artifact: c.base.artifact,
        profile: c.base.profile,
        workload: workload
      )

    {:ok, handle} = Machines.create(c.runtime, spec)
    true = handle == c.handle
    wait_machine(c.runtime, handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, handle, :start)
    record = wait_machine(c.runtime, handle, &(&1.state == :running))
    verify(c, "first", 1)
    diagnostics(c)

    IO.puts(
      Jason.encode!(%{
        phase: "prepare",
        machine_name: record.machine_name,
        workload_verified: true,
        retained: true
      })
    )
  end

  defp execute("resume", c) do
    {:ok, record} = Machines.inspect(c.runtime, c.handle)
    true = record.spec.workload.cmd == ["-c", @program]
    {:ok, handle} = Machines.create(c.runtime, record.spec)
    true = handle == c.handle
    verify(c, "recovered", 1)
    {:ok, _} = lifecycle(c.runtime, c.handle, :stop)
    wait_machine(c.runtime, c.handle, &(&1.state == :stopped))
    {:ok, %{slots: 1}} = Store.usage(c.store, "example-worker")
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))
    verify(c, "restarted", 2)
    diagnostics(c)

    IO.puts(
      Jason.encode!(%{
        phase: "resume",
        machine_name: record.machine_name,
        controller_recovered: true,
        startup_count: 2
      })
    )

    execute("delete", c)
  end

  defp execute("delete", c), do: delete_machine(c)

  defp verify(c, suffix, count) do
    program =
      "import pathlib,time\np=pathlib.Path('/workspace/workload-starts')\nfor _ in range(30):\n if p.exists() and len(p.read_text().splitlines()) == #{count}: break\n time.sleep(0.1)\nassert p.read_text() == 'configured:/\\n' * #{count}\nprint('verified')"

    command(c.runtime, c.handle, c.base, suffix, program, "verified\n")
  end

  defp diagnostics(c) do
    {:ok, %{source: :console, lines: lines}} = Machines.logs(c.runtime, c.handle, tail: 20)
    true = lines != []
    false = Enum.any?(lines, &(String.trim(&1) == "application-stdout-is-not-console"))
    parent = self()

    {:error, %{category: :transport}} =
      Machines.logs(c.runtime, c.handle,
        tail: 1,
        follow: true,
        timeout_ms: 1000,
        on_event: fn {:log, _line} -> send(parent, :console_event) end
      )

    receive do
      :console_event -> :ok
    after
      1000 -> raise "no console follow event received"
    end

    IO.puts(
      Jason.encode!(%{
        console_snapshot_lines: length(lines),
        console_follow: true,
        app_stdout_available: false
      })
    )
  end
end
