defmodule SmolBox.Example.Setup do
  @moduledoc false
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Client, Command, ExecutionSpec, Files, Profile, Worker}
  alias SmolBox.Runtime.WorkerConfig

  @program """
  import pathlib, sys, time
  root = pathlib.Path('/workspace')
  with (root / 'count').open('ab') as counter:
      counter.write(b'x')
  print('started', flush=True)
  if '--wait' in sys.argv:
      time.sleep(30)
  data = (root / 'input.bin').read_bytes()
  (root / 'output.bin').write_bytes(data[::-1])
  print('done', flush=True)
  """

  def environment do
    %{
      "url" => System.fetch_env!("SMOLBOX_RUNTIME_URL"),
      "artifact_path" => System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
      "artifact_sha256" => System.fetch_env!("SMOLBOX_PYTHON_SHA256"),
      "artifact_root" => System.fetch_env!("SMOLBOX_ARTIFACT_ROOT"),
      "fingerprint_key_file" => System.fetch_env!("SMOLBOX_FINGERPRINT_KEY_FILE"),
      "id" => System.fetch_env!("SMOLBOX_EXECUTION_ID"),
      "wait" => System.get_env("SMOLBOX_EXAMPLE_WAIT", "false") == "true"
    }
  end

  def build(settings, store, mode, name) do
    artifact_file = settings["artifact_path"]
    true = digest_file(artifact_file) == settings["artifact_sha256"]
    {:ok, objects} = Directory.new(settings["artifact_root"])
    :ok = Directory.seed(objects, "example", "program-v1", @program)
    :ok = Directory.seed(objects, "example", "input-v1", <<0, 255, 7>>)
    {:ok, profile} = Profile.new("example-offline-v1", execution_ms: 5000)

    artifact = %{
      "id" => "python-example-v1",
      "sha256" => settings["artifact_sha256"],
      "architecture" => architecture()
    }

    {:ok, endpoint} = Worker.new("example-worker", settings["url"], endpoint_options())
    {:ok, client} = Client.new(endpoint)

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        architecture: architecture(),
        platform: platform(),
        profiles: [profile],
        artifacts: [Map.put(artifact, "path", artifact_file)],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2}
      )

    options = [
      name: name,
      namespace: "sbxexample",
      mode: mode,
      store: store,
      artifact_store: {Directory, objects},
      fingerprint_key: key(settings["fingerprint_key_file"]),
      workers: [worker],
      poll_ms: 100,
      lease_ms: 2000
    ]

    {options, execution_spec(settings, artifact, profile), objects}
  end

  def key(file) do
    {:ok, %{type: :regular, size: 32}} = File.lstat(file)
    bytes = File.read!(file)
    true = byte_size(bytes) == 32
    bytes
  end

  def digest_file(file) do
    file
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def wait_for(runtime, handle, predicate, timeout \\ 90_000),
    do: observe(runtime, handle, predicate, System.monotonic_time(:millisecond) + timeout)

  defp observe(runtime, {scope, id} = handle, predicate, deadline) do
    {:ok, record} = SmolBox.fetch(runtime, scope, id)

    cond do
      predicate.(record) ->
        record

      System.monotonic_time(:millisecond) >= deadline ->
        raise "example observation deadline elapsed"

      true ->
        pause(runtime, handle, predicate, deadline)
    end
  end

  def describe(record) do
    %{
      scope: record.scope,
      id: record.id,
      worker_id: record.worker_id,
      machine_name: record.machine_name,
      state: record.state,
      evidence: record.evidence,
      collection: record.collection,
      cleanup: record.cleanup,
      reserved: record.reservation != nil,
      cancel_requested_at_ms: record.cancel_requested_at_ms,
      absence_at_ms: record.absence_at_ms,
      exit_code: if(record.result, do: record.result.exit_code),
      artifacts: record.artifacts
    }
  end

  defp pause(runtime, handle, predicate, deadline) do
    receive do
    after
      100 -> observe(runtime, handle, predicate, deadline)
    end
  end

  defp execution_spec(settings, artifact, profile) do
    argv = ["python", "/workspace/main.py"] ++ if(settings["wait"], do: ["--wait"], else: [])
    {:ok, command} = Command.new(argv, timeout_secs: 5)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "example",
        id: settings["id"],
        artifact: artifact,
        profile: profile,
        command: command,
        retention_ms: 60_000,
        inputs: [
          input("program-v1", "/workspace/main.py", @program),
          input("input-v1", "/workspace/input.bin", <<0, 255, 7>>)
        ],
        outputs: [
          %{"destination" => "output", "path" => "/workspace/output.bin", "max_bytes" => 32},
          %{"destination" => "count", "path" => "/workspace/count", "max_bytes" => 32}
        ]
      )

    spec
  end

  defp input(reference, path, bytes),
    do: %{
      "source" => reference,
      "path" => path,
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

  defp endpoint_options do
    case System.get_env("SMOLBOX_PROXY_TOKEN") do
      nil -> [allow_insecure_loopback: true]
      token -> [token: token]
    end
  end

  defp platform, do: if(:os.type() == {:unix, :darwin}, do: :macos, else: :linux)

  defp architecture do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      String.starts_with?(architecture, "aarch64") -> "aarch64"
      String.starts_with?(architecture, "x86_64") -> "x86_64"
      true -> raise "example host architecture is unqualified"
    end
  end
end
