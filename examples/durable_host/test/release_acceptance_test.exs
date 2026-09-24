defmodule SmolBox.DurableHost.ReleaseAcceptanceTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    Files,
    GuestPaths,
    LaunchResult,
    Machines,
    ManagedMachineSpec,
    PortMapping,
    Runtime,
    Terminal,
    Workload
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.Store.Codec
  alias SmolBox.Terminal.Spec, as: TerminalSpec
  import SmolBox.DurableHost.PersistentSteps

  @moduletag :runtime
  @moduletag timeout: 180_000
  @bytes 16_777_216
  @boot ~S"""
  import pathlib, os, time
  p = pathlib.Path('/app'); p.mkdir(exist_ok=True)
  with (p / 'starts').open('a') as f:
      f.write(os.environ['RELEASE'] + '\n'); f.flush(); os.fsync(f.fileno())
  time.sleep(900)
  """
  @server ~S"""
  import pathlib, http.server, os
  with pathlib.Path('/app/launches').open('a') as f:
      f.write('launched\n'); f.flush(); os.fsync(f.fileno())
  http.server.HTTPServer(('0.0.0.0', 8000), http.server.SimpleHTTPRequestHandler).serve_forever()
  """

  test "0.2.0 features compose on one retained machine across fresh controllers" do
    c = context()

    try do
      phase = System.fetch_env!("SMOLBOX_RELEASE_PHASE")
      run(phase, c)
      IO.puts(Jason.encode!(%{release: "0.2.0", phase: phase, integrated_acceptance: true}))
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

    {options, base, _} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)

    {:ok, paths} =
      GuestPaths.new(upload_roots: ["/app"], download_roots: ["/app"], workdir_roots: ["/app"])

    profile = %{
      base.profile
      | id: "release-020",
        guest_paths: paths,
        max_file_bytes: @bytes,
        max_total_file_bytes: 2 * @bytes,
        execution_ms: 330_000
    }

    [worker] = options[:workers]

    {:ok, client} =
      Client.new(
        %{worker.client.worker | max_request_bytes: @bytes, operation_timeout_ms: 330_000},
        guest_paths: paths,
        max_file_bytes: @bytes
      )

    worker = %{worker | profiles: [profile], client: client}
    {:ok, objects} = Directory.new(settings["artifact_root"], max_file_bytes: @bytes)
    bytes = :binary.copy(<<0, 255, 13, 10>>, div(@bytes, 4))
    :ok = Directory.seed(objects, "release-020", "input", bytes)
    options = Keyword.merge(options, workers: [worker], artifact_store: {Directory, objects})
    {:ok, runtime} = Runtime.start_link(options)

    %{
      runtime: runtime,
      handle: {"release-020", settings["id"]},
      store: store,
      client: client,
      base: %{base | profile: profile},
      objects: objects,
      digest: Files.sha256(bytes),
      port: String.to_integer(System.fetch_env!("SMOLBOX_RELEASE_PORT"))
    }
  end

  defp run("prepare", c) do
    # The chosen port is private to the qualification worker. Refuse an occupied port.
    {:ok, socket} = :gen_tcp.listen(c.port, ip: {127, 0, 0, 1}, active: false)
    :ok = :gen_tcp.close(socket)
    {:ok, mapping} = PortMapping.new(host: c.port, guest: 8000)

    {:ok, workload} =
      Workload.new(
        entrypoint: ["python", "-c"],
        cmd: [@boot],
        env: [{"RELEASE", "0.2.0"}],
        workdir: "/"
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1),
        artifact: c.base.artifact,
        profile: c.base.profile,
        ports: [mapping],
        workload: workload
      )

    {:ok, handle} = Machines.create(c.runtime, spec)
    assert handle == c.handle
    wait_machine(c.runtime, c.handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    machine = wait_machine(c.runtime, c.handle, &(&1.state == :running))
    assert {:ok, <<"smolbox-record-v9", 0, _::binary>>} = Codec.encode(machine)

    inputs = [
      %{
        "source" => "input",
        "path" => "/app/input.bin",
        "size" => @bytes,
        "sha256" => c.digest,
        "mode" => "runtime_default"
      }
    ]

    outputs = [%{"destination" => "result", "path" => "/app/output.bin", "max_bytes" => @bytes}]

    program =
      "import pathlib,hashlib,os; assert os.getcwd() == '/app'; p=pathlib.Path('input.bin').read_bytes(); assert len(p)==16777216; pathlib.Path('output.bin').write_bytes(p); pathlib.Path('release.txt').write_text('release-0.2.0'); print(hashlib.sha256(p).hexdigest())"

    {:ok, command} = Command.new(["python", "-c", program], workdir: "/app", timeout_secs: 301)
    request = request(c, "files", command, inputs: inputs, outputs: outputs)
    {:ok, execution} = Machines.submit(c.runtime, c.handle, request)

    assert {:ok, %{state: :completed, result: %{exit_code: 0, stdout: digest}}} =
             SmolBox.await(c.runtime, execution, 120_000)

    assert digest == c.digest <> "\n"
    {:ok, data} = Directory.read_output(c.objects, execution, "result", @bytes)
    assert Files.sha256(data) == c.digest
    idle(c)
    background(c, "server")
    ready(c, 100)
    terminal(c)

    assert {:ok, %{source: :console}} =
             Machines.logs(c.runtime, c.handle, tail: 10, follow: false)

    verify(c, "prepared", 1, 1)

    IO.puts(
      Jason.encode!(%{
        machine_name: machine.machine_name,
        bytes: @bytes,
        sha256: c.digest,
        configured_foreground_timeout_secs: 301,
        foreground_duration_probe: false,
        background_http: true,
        terminal_input_resize_exit: true,
        console_snapshot: true
      })
    )
  end

  defp run("delete", c), do: delete_machine(c)

  defp run("resume", c) do
    {:ok, machine} = Machines.inspect(c.runtime, c.handle)
    assert machine.spec.profile == c.base.profile
    assert machine.spec.workload.env == [{"RELEASE", "0.2.0"}]
    assert [%{host: port, guest: 8000}] = machine.spec.ports
    assert port == c.port
    background(c, "server")
    ready(c, 100)
    verify(c, "recovered", 1, 1)
    {:ok, _} = lifecycle(c.runtime, c.handle, :stop)
    wait_machine(c.runtime, c.handle, &(&1.state == :stopped))
    assert {:ok, %{slots: 1, disk_gb: 4}} = Store.usage(c.store, "example-worker")
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))
    verify(c, "restarted", 2, 1)
    background(c, "server-after-restart")
    ready(c, 100)
    verify(c, "relaunched", 2, 2)
    delete_machine(c)

    assert %{rows: [[0]]} =
             Database.query(
               c.store,
               "SELECT count(*) FROM smolbox_port_owners WHERE partition = $1",
               [c.store.partition]
             )

    IO.puts(
      Jason.encode!(%{
        machine_name: machine.machine_name,
        same_machine: true,
        controller_recovery: true,
        background_deduplicated: true,
        stop_start_files: true,
        workload_restarted: true,
        ports_released: true
      })
    )
  end

  defp background(c, suffix) do
    {:ok, command} = Command.new(["python", "-c", @server], workdir: "/app", background: true)
    spec = request(c, suffix, command)
    {:ok, key} = Machines.submit(c.runtime, c.handle, spec)

    assert {:ok, %{state: :launched, result: %LaunchResult{pid: pid}}} =
             SmolBox.await(c.runtime, key, 30_000)

    assert pid > 0
    idle(c)
  end

  defp verify(c, suffix, starts, launches) do
    program =
      "import pathlib,hashlib; p=pathlib.Path('/app'); assert len((p/'starts').read_text().splitlines()) == #{starts}; assert len((p/'launches').read_text().splitlines()) == #{launches}; assert (p/'terminal.txt').read_text() == 'terminal-retained'; assert hashlib.sha256((p/'input.bin').read_bytes()).hexdigest() == '#{c.digest}'; print('verified')"

    {:ok, command} = Command.new(["python", "-c", program], workdir: "/app", timeout_secs: 10)
    {:ok, key} = Machines.submit(c.runtime, c.handle, request(c, suffix, command))

    assert {:ok, %{state: :completed, result: %{exit_code: 0, stdout: "verified\n"}}} =
             SmolBox.await(c.runtime, key, 30_000)

    idle(c)
  end

  defp terminal(c) do
    {:ok, command} = TerminalSpec.new(program: "/bin/sh", session_ms: 30_000, idle_ms: 30_000)
    {:ok, key} = Terminal.open(c.runtime, c.handle, request(c, "terminal", command))
    {:ok, handle} = Terminal.attach(c.runtime, key, 30_000)
    :ok = Terminal.resize(handle, 101, 39)

    :ok =
      Terminal.input(
        handle,
        "stty -echo; stty size; cat /app/release.txt; printf terminal-retained > /app/terminal.txt; exit 7\n"
      )

    output = terminal_output(handle, "")
    assert output =~ "39 101"
    assert output =~ "release-0.2.0"

    assert {:ok, %{state: :completed, result: %Terminal.Result{exit_code: 7}}} =
             SmolBox.await(c.runtime, key, 30_000)

    idle(c)
  end

  defp terminal_output(handle, captured) do
    case Terminal.next(handle, 30_000) do
      {:ok, {:output, bytes}} -> terminal_output(handle, captured <> bytes)
      {:ok, {:closed, {:ok, %Terminal.Result{exit_code: 7}}}} -> captured
      unexpected -> flunk("terminal failed: #{inspect(unexpected)}")
    end
  end

  defp request(c, suffix, command, options \\ []) do
    {:ok, spec} =
      ExecutionSpec.new(
        [
          scope: elem(c.handle, 0),
          id: elem(c.handle, 1) <> "-" <> suffix,
          artifact: c.base.artifact,
          profile: c.base.profile,
          command: command
        ] ++ options
      )

    spec
  end

  defp idle(c), do: wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))

  defp ready(_c, 0), do: flunk("mapped HTTP service never became ready")

  defp ready(c, remaining) do
    case Req.get("http://127.0.0.1:#{c.port}/release.txt",
           retry: false,
           receive_timeout: 1000,
           connect_options: [timeout: 1000]
         ) do
      {:ok, %{status: 200, body: "release-0.2.0"}} ->
        :ok

      _ ->
        Process.sleep(100)
        ready(c, remaining - 1)
    end
  end
end
