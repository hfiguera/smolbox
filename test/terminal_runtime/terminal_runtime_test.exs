defmodule SmolBox.TerminalRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    Machine,
    Machines,
    ManagedMachineSpec,
    Profile,
    Runtime,
    TestArtifacts,
    Worker
  }

  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.Memory

  @moduletag :runtime
  @moduletag timeout: 420_000

  setup do
    path = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")

    digest =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    platform = if :os.type() == {:unix, :darwin}, do: :macos, else: :linux
    architecture = if platform == :macos, do: "aarch64", else: "x86_64"
    artifact = %{"id" => "extended-python", "sha256" => digest, "architecture" => architecture}

    endpoint = [
      allow_insecure_loopback: true,
      operation_timeout_ms: 355_000,
      receive_timeout_ms: 120_000
    ]

    endpoint =
      case System.get_env("SMOLBOX_RUNTIME_SOCKET") do
        nil -> endpoint
        socket -> Keyword.put(endpoint, :unix_socket, socket)
      end

    {:ok, worker} =
      Worker.new("extended-worker", System.fetch_env!("SMOLBOX_RUNTIME_URL"), endpoint)

    {:ok, client} = Client.new(worker)
    assert {:ok, %{version: "1.17.0"}} = Client.health(client)

    {:ok, profile} =
      Profile.new("extended-v1",
        storage_gb: 2,
        overlay_gb: 2,
        host_overhead_mb: 768,
        preparation_ms: 120_000,
        execution_ms: 360_000
      )

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        architecture: architecture,
        platform: platform,
        profiles: [profile],
        artifacts: [Map.put(artifact, "path", path)],
        allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768},
        capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 4}
      )

    store = start_supervised!(Memory)
    objects = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: SmolBox.TerminalRuntime,
      namespace: "terminal",
      mode: :ephemeral,
      store: {Memory, store},
      fingerprint_key: :crypto.strong_rand_bytes(32),
      artifact_store: {TestArtifacts, objects},
      workers: [worker],
      poll_ms: 100,
      lease_ms: 2000
    ]

    runtime = start_supervised!({Runtime, options})

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "extended",
        id: "machine",
        artifact: artifact,
        profile: profile
      )

    {:ok, handle} = Machines.create(runtime, spec)
    assert {:ok, %{state: :created} = created} = Machines.await(runtime, handle, 150_000)
    on_exit(fn -> cleanup(client, created.created_machine) end)
    {:ok, _} = Machines.start(runtime, handle, created.version)
    assert {:ok, %{state: :running} = machine} = Machines.await(runtime, handle, 150_000)

    %{
      runtime: runtime,
      options: options,
      client: client,
      machine: machine,
      handle: handle,
      artifact: artifact,
      profile: profile,
      store: store
    }
  end

  test "interactive shell input, resize, control character, exit and retained files", c do
    alias SmolBox.Terminal

    {:ok, terminal_spec} =
      Terminal.Spec.new(session_ms: 60_000, idle_ms: 30_000, cols: 91, rows: 37)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "extended",
        id: "terminal",
        artifact: c.artifact,
        profile: c.profile,
        command: terminal_spec
      )

    {:ok, key} = Terminal.open(c.runtime, c.handle, spec)
    assert {:ok, terminal} = Terminal.attach(c.runtime, key, 30_000)
    assert :ok = Terminal.input(terminal, "stty -echo; stty size\n")
    initial = until_output(terminal, "37 91", "")

    other =
      start_supervised!({Runtime, Keyword.put(c.options, :name, SmolBox.OtherTerminalRuntime)},
        id: :other
      )

    {:ok, busy} = Machines.inspect(other, c.handle)

    for operation <- [:stop, :delete] do
      assert {:error, %{category: :admission_exhausted}} =
               apply(Machines, operation, [other, c.handle, busy.version])
    end

    assert {:error, %{category: :expired}} = Terminal.attach(other, key, 0)

    assert :ok =
             Terminal.input(
               terminal,
               "printf retained-terminal > /workspace/terminal.txt; printf 'FILE_OK\\n'\n"
             )

    until_output(terminal, "FILE_OK", "")
    assert :ok = Terminal.resize(terminal, 113, 43)
    assert :ok = Terminal.input(terminal, "stty size\n")
    resized = until_output(terminal, "43 113", "")
    assert :ok = Terminal.input(terminal, "sleep 30\n")
    Process.sleep(200)
    started = System.monotonic_time(:millisecond)
    assert :ok = Terminal.input(terminal, <<3>>)
    assert :ok = Terminal.input(terminal, "printf 'INTERRUPT_OK\\n'\n")
    until_output(terminal, "INTERRUPT_OK", "")
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5000
    assert :ok = Terminal.input(terminal, "exit 7\n")
    assert {:ok, %Terminal.Result{exit_code: 7}} = until_closed(terminal)

    assert {:ok, %{state: :completed, result: %Terminal.Result{exit_code: 7}}} =
             SmolBox.await(c.runtime, key, 10_000)

    assert {:ok, %{active_execution: nil, reservation: %{slots: 1}}} =
             Machines.await(c.runtime, c.handle, 10_000)

    {:ok, command} = Command.new(["cat", "/workspace/terminal.txt"])
    {:ok, next} = Machines.submit(c.runtime, c.handle, %{spec | id: "read", command: command})

    assert {:ok, %{result: %{exit_code: 0, stdout: "retained-terminal"}}} =
             SmolBox.await(c.runtime, next, 30_000)

    assert {:ok, %{active_execution: nil}} = Machines.await(c.runtime, c.handle, 10_000)

    IO.puts(
      Jason.encode!(%{
        case: "interactive",
        initial_size: String.contains?(initial, "37 91"),
        resized: String.contains?(resized, "43 113"),
        interrupt_ms: elapsed,
        competing_controller_blocked: true,
        exit_code: 7,
        retained_file: true
      })
    )

    delete(c)
  end

  test "a stopped output consumer is bounded and closes observation without claiming exit", c do
    alias SmolBox.Terminal
    {:ok, spec} = Terminal.Spec.new(max_buffer_bytes: 4096, session_ms: 30_000)
    {:ok, terminal} = Client.open_terminal(c.client, c.machine.machine_name, spec)
    assert :ok = Terminal.input(terminal, "yes noisy-terminal\n")
    Process.sleep(1000)
    info = Process.info(terminal.pid, [:memory, :message_queue_len])
    assert info[:message_queue_len] < 10
    assert info[:memory] < 4_000_000
    assert {:error, %{category: :output_limit}} = until_closed(terminal)

    IO.puts(
      Jason.encode!(%{
        case: "slow-consumer",
        process_memory: info[:memory],
        queued_messages: info[:message_queue_len],
        outcome: "uncertain"
      })
    )

    delete(c)
  end

  test "abrupt terminal loss does not guarantee termination of detached descendants", c do
    # An intentionally detached descendant gives a concrete counterexample to
    # treating PTY disconnect as process-tree termination. All files/processes
    # are confined to this test's verified disposable guest.
    source = ~S"""
    import os, pathlib, signal, time
    root = pathlib.Path('/workspace')
    root.joinpath('terminal-parent.pid').write_text(str(os.getpid()))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        fd = os.open('/dev/null', os.O_RDWR)
        for target in range(3): os.dup2(fd, target)
        root.joinpath('terminal-child.pid').write_text(str(os.getpid()))
        while True:
            root.joinpath('terminal-heartbeat').write_text(str(time.monotonic_ns()))
            time.sleep(0.1)
    print('DESCENDANT_READY', flush=True)
    while True: time.sleep(1)
    """

    prepare =
      "from pathlib import Path; p=Path('/workspace/disconnect-program'); " <>
        "p.write_text(" <>
        Jason.encode!("#!/usr/local/bin/python3\n" <> source) <>
        "); p.chmod(0o755)"

    {:ok, command} = Command.new(["python3", "-c", prepare])
    assert {:ok, %{exit_code: 0}} = Client.exec(c.client, c.machine.machine_name, command)
    {:ok, spec} = SmolBox.Terminal.Spec.new(program: "/workspace/disconnect-program")
    {:ok, terminal} = Client.open_terminal(c.client, c.machine.machine_name, spec)
    until_output(terminal, "DESCENDANT_READY", "")
    monitor = Process.monitor(terminal.pid)
    Process.exit(terminal.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert {:error, %{category: :unknown}} = SmolBox.Terminal.next(terminal)

    check = ~S"""
    import os, pathlib, signal, time
    root = pathlib.Path('/workspace')
    time.sleep(0.5)
    before = root.joinpath('terminal-heartbeat').read_text()
    time.sleep(0.5)
    after = root.joinpath('terminal-heartbeat').read_text()
    parent = int(root.joinpath('terminal-parent.pid').read_text())
    child = int(root.joinpath('terminal-child.pid').read_text())
    print('descendant_active=' + str(before != after))
    print('direct_child_present=' + str(pathlib.Path('/proc/' + str(parent)).exists()))
    os.kill(child, signal.SIGKILL)
    """

    {:ok, command} = Command.new(["python3", "-c", check])

    assert {:ok, %{exit_code: 0, stdout: observation}} =
             Client.exec(c.client, c.machine.machine_name, command)

    assert observation =~ "descendant_active=True"
    IO.puts(Jason.encode!(%{case: "abrupt-disconnect", observation: observation}))
    delete(c)
  end

  defp until_output(terminal, marker, acc) do
    assert byte_size(acc) < 65_536
    assert {:ok, {:output, bytes}} = SmolBox.Terminal.next(terminal, 5000)
    data = acc <> bytes
    if String.contains?(data, marker), do: data, else: until_output(terminal, marker, data)
  end

  defp until_closed(terminal) do
    case SmolBox.Terminal.next(terminal, 5000) do
      {:ok, {:output, _bytes}} -> until_closed(terminal)
      {:ok, {:closed, outcome}} -> outcome
      other -> flunk("missing terminal outcome: #{inspect(other)}")
    end
  end

  defp delete(c) do
    {:ok, idle} = Machines.inspect(c.runtime, c.handle)
    {:ok, _} = Machines.delete(c.runtime, c.handle, idle.version)

    assert {:ok, %{state: :deleted, reservation: nil}} =
             Machines.await(c.runtime, c.handle, 90_000)

    assert {:ok, %{slots: 0}} = Memory.usage(c.store, "extended-worker")

    assert {:error, %{category: :not_found}} =
             Client.inspect_machine(c.client, c.machine.machine_name)
  end

  defp cleanup(client, created) do
    case Client.inspect_machine(client, created.name) do
      {:error, %{category: :not_found}} ->
        :ok

      {:ok, observed} ->
        assert Machine.same_incarnation?(created, observed)
        assert :ok = Client.delete(client, created.name)
        assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
    end
  end
end
