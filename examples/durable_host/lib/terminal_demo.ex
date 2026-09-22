defmodule SmolBox.DurableHost.TerminalDemo do
  @moduledoc "Durable terminal use and explicit recovery across separate controller processes."
  alias SmolBox.{Client, ExecutionSpec, Machine, Machines, ManagedMachineSpec, Runtime, Terminal}
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Example.{Setup, TerminalConsole}
  import SmolBox.DurableHost.PersistentSteps

  @prepare ~S"""
  import pathlib
  p = pathlib.Path('/workspace/terminal-program')
  p.write_text('#!/bin/sh\necho started >> /workspace/terminal-starts\nexec /bin/sh\n')
  p.chmod(0o755)
  print('prepared')
  """

  def run(phase)
      when phase in ["run", "interrupt", "recover", "shell", "delete", "stop-for-drain"] do
    c = context()

    try do
      execute(phase, c)
    after
      Supervisor.stop(c.runtime)
    end
  end

  defp context do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _objects} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)
    profile = %{base.profile | id: "terminal-demo-v1", execution_ms: 300_000}
    workers = Enum.map(options[:workers], &%{&1 | profiles: [profile]})
    options = Keyword.put(options, :workers, workers)
    {:ok, runtime} = Runtime.start_link(options)

    %{
      runtime: runtime,
      handle: {"terminal-demo", settings["id"]},
      base: %{base | profile: profile},
      store: store,
      client: hd(workers).client
    }
  end

  defp execute("recover", c), do: recover(c)
  defp execute("delete", c), do: delete(c)

  defp execute("stop-for-drain", c) do
    # This prepares persistent disks for worker shutdown, but does NOT resolve
    # uncertainty. Old worker requests must still be drained before recover.
    {:ok, machine} = Machines.inspect(c.runtime, c.handle)
    {:ok, observed} = Client.inspect_machine(c.client, machine.machine_name)
    true = Machine.same_incarnation?(machine.created_machine, observed)
    {:ok, stopped} = Client.stop(c.client, machine.machine_name)
    true = stopped.state == :stopped
    true = Machine.same_incarnation?(machine.created_machine, stopped)
    IO.puts(Jason.encode!(%{phase: "stop-for-drain", uncertainty_resolved: false}))
  end

  defp execute(phase, c) do
    {scope, id} = c.handle

    {:ok, machine_spec} =
      ManagedMachineSpec.new(
        scope: scope,
        id: id,
        artifact: c.base.artifact,
        profile: c.base.profile
      )

    {:ok, _} = Machines.create(c.runtime, machine_spec)
    wait_machine(c.runtime, c.handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))
    command(c.runtime, c.handle, c.base, "prepare", @prepare, "prepared\n")
    {:ok, key} = Terminal.open(c.runtime, c.handle, terminal_spec(c))
    {:ok, live} = Terminal.attach(c.runtime, key, 30_000)
    continue(phase, c, key, live)
  end

  defp continue("shell", c, key, live) do
    outcome = TerminalConsole.run(live)
    IO.puts(inspect(outcome))
    # Live delivery can precede the store transaction. Keep the controller alive
    # until its durable outcome (and confirmed-exit slot cleanup) is observed.
    {:ok, record} = SmolBox.await(c.runtime, key, 30_000)

    if record.state == :completed,
      do: wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))

    IO.puts(
      Jason.encode!(%{
        phase: "shell",
        execution: Tuple.to_list(key),
        state: record.state,
        machine: Tuple.to_list(c.handle),
        retained: true
      })
    )
  end

  defp continue(phase, c, key, live) do
    :ok =
      Terminal.input(
        live,
        "stty -echo; printf retained-terminal > /workspace/terminal.txt; printf 'WRITTEN\\n'\n"
      )

    output_until(live, "WRITTEN", "")
    :ok = Terminal.resize(live, 101, 39)
    :ok = Terminal.input(live, "stty size\n")
    output_until(live, "39 101", "")
    if phase == "interrupt", do: interrupt(c, key), else: finish(c, key, live)
  end

  @spec interrupt(map(), {String.t(), String.t()}) :: no_return()
  defp interrupt(c, key) do
    {:ok, record} = SmolBox.fetch(c.runtime, elem(key, 0), elem(key, 1))
    true = record.state in [:dispatching, :running]

    IO.puts(
      Jason.encode!(%{
        phase: "interrupt",
        machine_name: record.machine_name,
        execution: Tuple.to_list(key),
        dispatch_persisted: true,
        retained_file_written: true
      })
    )

    # Deliberately bypass supervisor cleanup to demonstrate lost-controller recovery.
    System.halt(0)
  end

  defp finish(c, key, live) do
    :ok = Terminal.input(live, "exit 7\n")
    {:ok, %Terminal.Result{exit_code: 7}} = closed(live)

    {:ok, %{state: :completed, result: %Terminal.Result{exit_code: 7}}} =
      SmolBox.await(c.runtime, key, 30_000)

    wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))
    read_retained(c)
    delete(c)

    IO.puts(
      Jason.encode!(%{
        phase: "run",
        exit_code: 7,
        resize_verified: true,
        retained_file: true,
        absence_verified: true,
        reservations_released: true
      })
    )
  end

  defp recover(c) do
    # This assertion is operator evidence, not inferred from a stopped observation.
    # Drain/fence old controllers and worker requests before invoking this phase.
    true = System.get_env("SMOLBOX_TERMINAL_QUIESCED") == "true"
    spec = terminal_spec(c)
    key = {spec.scope, spec.id}
    {:ok, %{state: :unknown, result: nil}} = SmolBox.await(c.runtime, key, 30_000)
    {:ok, machine} = Machines.await(c.runtime, c.handle, 30_000)
    true = machine.state == :unknown and machine.active_execution == key
    {:ok, ^key} = Terminal.open(c.runtime, c.handle, spec)
    {:error, %{category: :unknown}} = Terminal.attach(c.runtime, key, 0)

    {:error, %{category: :admission_exhausted}} =
      Machines.delete(c.runtime, c.handle, machine.version)

    {:ok, observed} = Client.inspect_machine(c.client, machine.machine_name)
    true = Machine.same_incarnation?(machine.created_machine, observed)
    {:ok, stopped} = Client.stop(c.client, machine.machine_name)

    true =
      stopped.state == :stopped and Machine.same_incarnation?(machine.created_machine, stopped)

    {:ok, current} = Machines.inspect(c.runtime, c.handle)

    {:ok, %{active_execution: nil}} =
      Machines.resolve(c.runtime, c.handle, current.version, quiesced: true)

    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))
    read_retained(c)

    command(
      c.runtime,
      c.handle,
      c.base,
      "count",
      "from pathlib import Path; print(len(Path('/workspace/terminal-starts').read_text().splitlines()))",
      "1\n"
    )

    delete(c)
    {:ok, ^key} = Terminal.open(c.runtime, c.handle, spec)

    IO.puts(
      Jason.encode!(%{
        phase: "recover",
        unknown_preserved: true,
        no_replay: true,
        retained_file: true,
        deduplication_retained: true,
        absence_verified: true,
        reservations_released: true
      })
    )
  end

  defp terminal_spec(c) do
    {scope, id} = c.handle

    {:ok, terminal} =
      Terminal.Spec.new(
        program: "/workspace/terminal-program",
        session_ms: 300_000,
        idle_ms: 300_000
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: scope,
        id: id <> "-terminal",
        artifact: c.base.artifact,
        profile: c.base.profile,
        command: terminal
      )

    spec
  end

  defp read_retained(c),
    do:
      command(
        c.runtime,
        c.handle,
        c.base,
        "read",
        "from pathlib import Path; print(Path('/workspace/terminal.txt').read_text())",
        "retained-terminal\n"
      )

  defp delete(c) do
    {:ok, before} = Machines.inspect(c.runtime, c.handle)
    {:ok, _} = lifecycle(c.runtime, c.handle, :delete)
    deleted = wait_machine(c.runtime, c.handle, &(&1.state == :deleted))
    true = deleted.reservation == nil and deleted.reserved_ports == []
    {:error, %{category: :not_found}} = Client.inspect_machine(c.client, before.machine_name)
    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(c.store, "example-worker")

    %{rows: [[0]]} =
      Database.query(c.store, "SELECT count(*) FROM smolbox_port_owners WHERE partition = $1", [
        c.store.partition
      ])
  end

  defp output_until(live, marker, acc) do
    true = byte_size(acc) < 65_536
    {:ok, {:output, bytes}} = Terminal.next(live, 10_000)
    data = acc <> bytes
    if String.contains?(data, marker), do: :ok, else: output_until(live, marker, data)
  end

  defp closed(live) do
    case Terminal.next(live, 10_000) do
      {:ok, {:output, _bytes}} -> closed(live)
      {:ok, {:closed, outcome}} -> outcome
    end
  end
end
