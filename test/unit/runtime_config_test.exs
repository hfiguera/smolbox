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
