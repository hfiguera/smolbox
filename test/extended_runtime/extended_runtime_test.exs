defmodule SmolBox.ExtendedRuntimeTest do
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
    version = SmolBox.LabCandidate.runtime_version()
    assert {:ok, %{version: ^version}} = Client.health(client)

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
        runtime_version: SmolBox.LabCandidate.runtime_version(),
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

    runtime =
      start_supervised!(
        {Runtime,
         [
           name: SmolBox.ExtendedRuntime,
           namespace: "longexec",
           mode: :ephemeral,
           store: {Memory, store},
           fingerprint_key: :crypto.strong_rand_bytes(32),
           artifact_store: {TestArtifacts, objects},
           workers: [worker],
           poll_ms: 100,
           lease_ms: 2000
         ]}
      )

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
      client: client,
      machine: machine,
      handle: handle,
      artifact: artifact,
      profile: profile,
      store: store
    }
  end

  test "buffered foreground command remains quiet for more than 300 seconds", c do
    {:ok, command} =
      Command.new(
        [
          "python",
          "-c",
          "import time; time.sleep(305); print('buffered-finished'); raise SystemExit(7)"
        ],
        timeout_secs: 330
      )

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{exit_code: 7, stdout: "buffered-finished\n", encoding: :bytes}} =
             Client.exec(c.client, c.machine.machine_name, command)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 305_000

    IO.puts(
      Jason.encode!(%{
        case: "long-buffered",
        elapsed_ms: elapsed,
        exit_code: 7,
        quiet_seconds: 305
      })
    )

    delete(c)
  end

  test "managed streaming command survives quiet time, lease renewals and caller await expiry",
       c do
    {:ok, command} =
      Command.new(
        [
          "python",
          "-c",
          "import time; time.sleep(305); print('streamed-finished'); raise SystemExit(9)"
        ],
        timeout_secs: 330
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "extended",
        id: "long-stream",
        artifact: c.artifact,
        profile: c.profile,
        command: command
      )

    started = System.monotonic_time(:millisecond)
    {:ok, execution} = Machines.submit(c.runtime, c.handle, spec)
    assert {:error, %{category: :expired}} = SmolBox.await(c.runtime, execution, 10)

    assert {:ok,
            %{
              state: :completed,
              result: %{exit_code: 9, stdout: "streamed-finished\n", encoding: :lossy_utf8}
            }} = SmolBox.await(c.runtime, execution, 365_000)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 305_000

    assert {:ok, %{active_execution: nil, reservation: %{slots: 1}}} =
             Machines.await(c.runtime, c.handle, 10_000)

    IO.puts(
      Jason.encode!(%{
        case: "long-managed-stream",
        elapsed_ms: elapsed,
        exit_code: 9,
        quiet_seconds: 305,
        await_expiry_did_not_cancel: true
      })
    )

    delete(c)
  end

  test "guest timeout and client observation timeout remain different outcomes", c do
    {:ok, timeout} = Command.new(["python", "-c", "import time; time.sleep(10)"], timeout_secs: 1)
    assert {:ok, %{exit_code: exit_code}} = Client.exec(c.client, c.machine.machine_name, timeout)
    assert exit_code != 0

    {:ok, command} =
      Command.new(
        [
          "python",
          "-c",
          "import time,pathlib; time.sleep(2); pathlib.Path('/workspace/after-timeout').write_text('alive')"
        ],
        timeout_secs: 5
      )

    short = %{c.client | worker: %{c.client.worker | operation_timeout_ms: 500}}

    assert {:error, %{category: :transport, evidence: :dispatch_uncertain}} =
             Client.exec(short, c.machine.machine_name, command)

    Process.sleep(2500)

    assert {:ok, "alive"} =
             Client.download(c.client, c.machine.machine_name, "/workspace/after-timeout", 100)

    IO.puts(
      Jason.encode!(%{
        case: "timeouts",
        guest_exit_code: exit_code,
        process_outlived_observation: true
      })
    )

    delete(c)
  end

  @tag :background_options
  test "background user, environment and workdir are honored without promising continued liveness",
       c do
    {:ok, prepare} = Command.new(["python", "-c", "import os; os.chmod('/workspace', 0o777)"])
    assert {:ok, %{exit_code: 0}} = Client.exec(c.client, c.machine.machine_name, prepare)

    program =
      "import os,pathlib,json; pathlib.Path('/workspace/options.json').write_text(json.dumps([os.getuid(),os.getcwd(),os.environ['LAUNCH_MODE']]))"

    {:ok, command} =
      Command.new(["python", "-c", program],
        background: true,
        user: "65534:65534",
        workdir: "/workspace",
        env: [{"LAUNCH_MODE", "verified"}]
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "extended",
        id: "background-options",
        artifact: c.artifact,
        profile: c.profile,
        command: command
      )

    {:ok, execution} = Machines.submit(c.runtime, c.handle, spec)

    assert {:ok, %{state: :launched, result: %SmolBox.LaunchResult{pid: pid}}} =
             SmolBox.await(c.runtime, execution, 30_000)

    assert pid > 0
    assert {:ok, %{active_execution: nil}} = Machines.await(c.runtime, c.handle, 10_000)

    {:ok, read} =
      Command.new(
        [
          "python",
          "-c",
          "import pathlib,time; p=pathlib.Path('/workspace/options.json');\nfor _ in range(50):\n if p.exists(): break\n time.sleep(.1)\nprint(p.read_text())"
        ],
        timeout_secs: 10
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "extended",
        id: "read-background-options",
        artifact: c.artifact,
        profile: c.profile,
        command: read
      )

    {:ok, execution} = Machines.submit(c.runtime, c.handle, spec)

    assert {:ok, %{state: :completed, result: %{exit_code: 0, stdout: output}}} =
             SmolBox.await(c.runtime, execution, 30_000)

    assert Jason.decode!(String.trim(output)) == [65_534, "/workspace", "verified"]
    assert {:ok, %{active_execution: nil}} = Machines.await(c.runtime, c.handle, 10_000)

    IO.puts(
      Jason.encode!(%{
        case: "background-options",
        pid: pid,
        uid: 65_534,
        env_and_workdir_verified: true
      })
    )

    delete(c)
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
