defmodule SmolBox.DurableHost.GuestFilesDemo do
  @moduledoc "Approved guest directories and 16 MiB files across durable controller recovery."
  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    Files,
    GuestPaths,
    Machines,
    ManagedMachineSpec,
    Runtime
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  import SmolBox.DurableHost.PersistentSteps

  @size 16_777_216
  @program ~S"""
  import hashlib, pathlib, os
  assert os.getcwd() == '/app/project'
  assert pathlib.Path('/home/dev/.config/smolbox/settings').read_text() == 'configured'
  data = pathlib.Path('input.bin').read_bytes()
  assert len(data) == 16777216
  pathlib.Path('output.bin').write_bytes(data)
  print(hashlib.sha256(data).hexdigest())
  """

  def run(phase) when phase in ["prepare", "resume", "delete"] do
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

    {:ok, paths} =
      GuestPaths.new(
        upload_roots: ["/app", "/home/dev/.config/smolbox"],
        download_roots: ["/app", "/home/dev/.config/smolbox"],
        workdir_roots: ["/app"]
      )

    profile = %{
      base.profile
      | id: "guest-files-v1",
        guest_paths: paths,
        max_file_bytes: @size,
        max_total_file_bytes: 2 * @size,
        execution_ms: 15_000
    }

    [worker] = options[:workers]

    {:ok, client} =
      Client.new(%{worker.client.worker | max_request_bytes: @size},
        guest_paths: paths,
        max_file_bytes: @size
      )

    worker = %{worker | client: client, profiles: [profile]}
    {:ok, objects} = Directory.new(settings["artifact_root"], max_file_bytes: @size)
    bytes = :binary.copy(<<0, 255, 13, 10>>, div(@size, 4))
    :ok = Directory.seed(objects, "guest-files", "binary", bytes)
    :ok = Directory.seed(objects, "guest-files", "config", "configured")

    options =
      options
      |> Keyword.put(:workers, [worker])
      |> Keyword.put(:artifact_store, {Directory, objects})

    {:ok, runtime} = Runtime.start_link(options)

    %{
      runtime: runtime,
      base: %{base | profile: profile},
      handle: {"guest-files", settings["id"]},
      store: store,
      objects: objects,
      client: client,
      digest: Files.sha256(bytes)
    }
  end

  defp execute("prepare", c) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1),
        artifact: c.base.artifact,
        profile: c.base.profile
      )

    {:ok, _} = Machines.create(c.runtime, spec)
    wait_machine(c.runtime, c.handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    machine = wait_machine(c.runtime, c.handle, &(&1.state == :running))

    input = %{
      "source" => "binary",
      "path" => "/app/project/input.bin",
      "size" => @size,
      "sha256" => c.digest,
      "mode" => "runtime_default"
    }

    config = %{
      "source" => "config",
      "path" => "/home/dev/.config/smolbox/settings",
      "size" => 10,
      "sha256" => Files.sha256("configured"),
      "mode" => "runtime_default"
    }

    output = %{
      "destination" => "result",
      "path" => "/app/project/output.bin",
      "max_bytes" => @size
    }

    execution = submit(c, "transfer", [input, config], [output])
    {:ok, bytes} = Directory.read_output(c.objects, execution, "result", @size)
    true = byte_size(bytes) == @size and Files.sha256(bytes) == c.digest

    IO.puts(
      Jason.encode!(%{
        phase: "prepare",
        machine_name: machine.machine_name,
        bytes: @size,
        sha256: c.digest,
        home_config: true,
        command_workdir: "/app/project",
        retained: true
      })
    )
  end

  defp execute("resume", c) do
    {:ok, machine} = Machines.inspect(c.runtime, c.handle)
    true = machine.spec.profile == c.base.profile
    submit(c, "recovered", [], [])
    {:ok, _} = lifecycle(c.runtime, c.handle, :stop)
    wait_machine(c.runtime, c.handle, &(&1.state == :stopped))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))
    submit(c, "restarted", [], [])

    IO.puts(
      Jason.encode!(%{
        phase: "resume",
        machine_name: machine.machine_name,
        policy_recovered: true,
        files_preserved: true,
        stop_start: true
      })
    )

    execute("delete", c)
  end

  defp execute("delete", c), do: delete_machine(c)

  defp submit(c, suffix, inputs, outputs) do
    {:ok, command} =
      Command.new(["python", "-c", @program], workdir: "/app/project", timeout_secs: 10)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1) <> "-" <> suffix,
        artifact: c.base.artifact,
        profile: c.base.profile,
        command: command,
        inputs: inputs,
        outputs: outputs
      )

    {:ok, execution} = Machines.submit(c.runtime, c.handle, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: digest}}} =
      SmolBox.await(c.runtime, execution, 120_000)

    true = digest == c.digest <> "\n"
    wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))
    execution
  end
end
