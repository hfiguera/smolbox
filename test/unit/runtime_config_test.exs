defmodule SmolBox.RuntimeConfigTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Error, Worker}
  alias SmolBox.Runtime.{Config, WorkerConfig}
  alias SmolBox.Store.{Contract, Memory}

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

  test "runtime upgrades are explicit and restricted to the supported host combination",
       context do
    assert context.worker.runtime_version == "1.14.1"

    assert {:ok, candidate} =
             WorkerConfig.new(Keyword.put(context.options, :runtime_version, "1.14.6"))

    assert :ok = WorkerConfig.validate(candidate)

    for {platform, architecture} <- [{:macos, "aarch64"}, {:linux, "aarch64"}] do
      worker = %{
        candidate
        | platform: platform,
          architecture: architecture,
          artifacts: Enum.map(candidate.artifacts, &Map.put(&1, "architecture", architecture))
      }

      assert {:error, %Error{category: :validation}} = WorkerConfig.validate(worker)
      assert :ok = WorkerConfig.validate(%{worker | runtime_version: "1.14.1"})
    end

    for version <- ["1.14.2", "1.14.5", "1.14.7", "1.14.6-dev"] do
      assert {:error, %Error{category: :validation}} =
               WorkerConfig.validate(%{candidate | runtime_version: version})
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
