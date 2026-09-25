defmodule SmolBox.RuntimeConfigTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Command, Error, Execution, ExecutionSpec, Worker}
  alias SmolBox.Runtime.{Config, WorkerConfig}
  alias SmolBox.Store.{Codec, Contract, Memory}
  alias SmolBox.Terminal.Spec

  setup do
    store = start_supervised!(Memory)

    {:ok, endpoint} =
      Worker.new("configured", "http://127.0.0.1:65534", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)
    spec = Contract.record().spec

    options = [
      client: client,
      platform: :linux,
      architecture: "x86_64",
      profiles: [spec.profile],
      allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
      capacity: Contract.capacity(),
      artifacts: [Map.put(spec.artifact, "path", "/approved/runtime.smolmachine")]
    ]

    {:ok, worker} = WorkerConfig.new(options)

    config = [
      name: SmolBox.ConfigTestRuntime,
      namespace: "config",
      store: {Memory, store},
      mode: :ephemeral,
      artifact_store: {SmolBox.TestArtifacts, nil},
      fingerprint_key: :binary.copy(<<1>>, 32),
      workers: [worker]
    ]

    %{worker: worker, options: options, config: config, spec: spec}
  end

  test "fixed ports require 1.17.0 while the same no-port approval remains compatible", c do
    {:ok, spec} =
      SmolBox.ManagedMachineSpec.new(
        scope: c.spec.scope,
        id: "ports",
        artifact: c.spec.artifact,
        profile: c.spec.profile,
        ports: [%SmolBox.PortMapping{host: 28_731, guest: 8000}]
      )

    assert WorkerConfig.supports?(c.worker, spec)
    assert {:ok, machine} = WorkerConfig.machine_spec(c.worker, spec, "ports")
    assert machine.ports == spec.ports
    refute WorkerConfig.supports?(%{c.worker | runtime_version: "1.16.1"}, spec)
    assert WorkerConfig.supports?(%{c.worker | runtime_version: "1.16.1"}, %{spec | ports: []})
    refute WorkerConfig.supports?(%{c.worker | platform: :windows}, spec)
  end

  test "record formats and worker admission preserve execution feature boundaries", c do
    {:ok, background} = Command.new(["server"], background: true)
    {:ok, terminal} = Spec.new(max_buffer_bytes: 1024)

    for {command, budget, version, legacy?} <- [
          {c.spec.command, 300_000, "v2", true},
          {c.spec.command, 300_001, "v6", false},
          {background, 30_000, "v6", false},
          {terminal, 30_000, "v7", false}
        ] do
      profile = %{c.spec.profile | execution_ms: budget}
      spec = %{c.spec | command: command, profile: profile}
      worker = %{c.worker | profiles: [profile]}
      assert WorkerConfig.supports?(worker, spec)
      assert WorkerConfig.supports?(%{worker | runtime_version: "1.16.1"}, spec) == legacy?

      {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
      {:ok, record} = Execution.new(spec, fingerprint, 1000)
      assert {:ok, bytes} = Codec.encode(record)
      assert String.starts_with?(bytes, "smolbox-record-" <> version <> <<0>>)
      assert {:ok, ^record} = Codec.decode(bytes)
    end
  end

  test "worker registration rejects unsafe catalogs, endpoints and unqualified controls",
       context do
    refute inspect(context.worker) =~ "/approved/"
    assert WorkerConfig.supports?(context.worker, context.spec)

    assert WorkerConfig.artifact_path(context.worker, context.spec) ==
             "/approved/runtime.smolmachine"

    for invalid <- [
          [],
          [unknown: true],
          [profiles: []],
          [artifacts: []],
          [capacity: %{}],
          [allocation_floor: nil],
          [allocation_floor: %{storage_gb: 1, overlay_gb: 1}],
          [allocation_floor: %{storage_gb: 65, overlay_gb: 1, host_overhead_mb: 256}],
          [allocation_floor: %{storage_gb: 1, overlay_gb: 0, host_overhead_mb: 256}],
          [allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 127}],
          [allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256, unknown: 1}],
          [runtime_version: "future"],
          [qualification: :production],
          [architecture: "arm32"],
          [platform: :macos],
          [draining: :yes],
          [client: %{}],
          [profiles: [context.spec.profile, context.spec.profile]],
          [artifacts: [%{"id" => "bad"}]]
        ] do
      options = if invalid == [], do: [], else: Keyword.merge(context.options, invalid)
      assert {:error, %Error{category: :validation}} = WorkerConfig.new(options)
    end

    assert {:error, %Error{}} = WorkerConfig.validate(%{})
    assert {:error, %Error{}} = WorkerConfig.validate(Map.put(context.worker, :surprise, true))
    forged_client = context.worker.client |> Map.delete(:worker) |> Map.put(:surprise, true)
    assert {:error, %Error{}} = WorkerConfig.validate(%{context.worker | client: forged_client})

    assert {:error, %Error{}} =
             WorkerConfig.new(Keyword.delete(context.options, :allocation_floor))
  end

  test "runtime defaults to 1.17.0 and accepts only qualified explicit versions",
       context do
    assert context.worker.runtime_version == "1.17.0"

    assert {:ok, %{runtime_version: "1.16.0"}} =
             WorkerConfig.new(Keyword.put(context.options, :runtime_version, "1.16.0"))

    assert {:ok, %{runtime_version: "1.14.1"}} =
             WorkerConfig.new(Keyword.put(context.options, :runtime_version, "1.14.1"))

    assert {:ok, candidate} =
             WorkerConfig.new(Keyword.put(context.options, :runtime_version, "1.14.6"))

    assert :ok = WorkerConfig.validate(candidate)

    for version <- ["1.14.6", "1.16.0", "1.16.1", "1.17.0"],
        {platform, architecture} <- [{:macos, "aarch64"}, {:linux, "aarch64"}] do
      worker = %{
        candidate
        | runtime_version: version,
          platform: platform,
          architecture: architecture,
          artifacts: Enum.map(candidate.artifacts, &Map.put(&1, "architecture", architecture))
      }

      if platform == :macos do
        assert :ok = WorkerConfig.validate(worker)
      else
        assert {:error, %Error{category: :validation}} = WorkerConfig.validate(worker)
      end

      assert :ok = WorkerConfig.validate(%{worker | runtime_version: "1.14.1"})
    end

    for version <- [
          "1.14.2",
          "1.14.5",
          "1.14.7",
          "1.14.6-dev",
          "1.15.1",
          "1.16.0-dev",
          "1.16.1-dev",
          "1.16.2",
          "1.17.0-dev",
          "1.17.1"
        ] do
      assert {:error, %Error{category: :validation}} =
               WorkerConfig.validate(%{candidate | runtime_version: version})
    end
  end

  test "1.17.0 default requires a supported platform", context do
    assert context.worker.runtime_version == "1.17.0"

    for {platform, architecture} <- [{:linux, "x86_64"}, {:macos, "aarch64"}] do
      artifacts = Enum.map(context.worker.artifacts, &Map.put(&1, "architecture", architecture))

      options =
        Keyword.merge(context.options,
          platform: platform,
          architecture: architecture,
          artifacts: artifacts
        )

      assert {:ok, worker} = WorkerConfig.new(options)
      assert :ok = WorkerConfig.validate(worker)

      assert {:error, %Error{category: :validation}} =
               WorkerConfig.validate(%{worker | platform: :linux, architecture: "aarch64"})
    end
  end

  test "template sizes and VMM overhead are explicit prerequisites for supported profiles",
       context do
    for {field, value} <- [storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768] do
      floor = Map.put(context.worker.allocation_floor, field, value)
      worker = %{context.worker | allocation_floor: floor}
      assert :ok = WorkerConfig.validate(worker)
      refute WorkerConfig.supports?(worker, context.spec)

      profile = Map.put(context.spec.profile, field, value)

      assert WorkerConfig.supports?(%{worker | profiles: [profile]}, %{
               context.spec
               | profile: profile
             })
    end
  end

  test "runtime bounds, store callbacks, and duplicate endpoint aliases are checked", context do
    assert {:ok, _config} = Config.new(context.config)
    assert {:ok, _empty} = Config.new(Keyword.put(context.config, :workers, []))

    alias_worker = %{
      context.worker
      | client: %{context.worker.client | worker: %{context.worker.client.worker | id: "alias"}}
    }

    for invalid <- [
          [name: nil],
          [namespace: "bad-namespace"],
          [store: :bad],
          [artifact_store: {String, nil}],
          [max_active: 65],
          [max_pending: 0],
          [telemetry_max_pending: 1025],
          [telemetry_timeout_ms: 1001],
          [poll_ms: 0],
          [lease_ms: 1000, poll_ms: 1000],
          [fingerprint_key: "short"],
          [clock: String],
          [workers: [context.worker, context.worker]],
          [workers: [context.worker, alias_worker]],
          [unknown: true]
        ] do
      assert {:error, %Error{category: :validation}} =
               Config.new(Keyword.merge(context.config, invalid))
    end
  end
end
