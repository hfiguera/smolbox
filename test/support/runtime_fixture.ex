defmodule SmolBox.RuntimeFixture do
  @moduledoc false
  alias SmolBox.{Client, ManagedPeer, Runtime, TestArtifacts, Worker}
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.{Contract, Memory}

  def start(options \\ []) do
    {peer, port} = ManagedPeer.start(options)
    store = ExUnit.Callbacks.start_supervised!(Memory)

    artifacts =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{{"contract", "input"} => <<0, 255>>} end}
      )

    {:ok, endpoint} =
      Worker.new("peer", "http://127.0.0.1:#{port}",
        allow_insecure_loopback: true,
        max_request_bytes: Keyword.get(options, :max_file_bytes, 1_048_576)
      )

    {:ok, client} =
      Client.new(endpoint,
        guest_paths: options[:guest_paths],
        max_file_bytes: Keyword.get(options, :max_file_bytes, 1_048_576)
      )

    spec = Contract.record().spec
    spec = %{spec | profile: %{spec.profile | network: Keyword.get(options, :network, :offline)}}

    spec = %{
      spec
      | profile: %{
          spec.profile
          | guest_paths: options[:guest_paths],
            max_file_bytes: Keyword.get(options, :max_file_bytes, 1_048_576)
        }
    }

    checkpoint? = Keyword.get(options, :checkpoint, false)

    spec =
      if checkpoint?,
        do: %{spec | artifact: Map.put(spec.artifact, "kind", "checkpoint")},
        else: spec

    checkpoints =
      if checkpoint? do
        {:ok, checkpoint} =
          SmolBox.Checkpoint.new(
            id: spec.artifact["id"],
            sha256: spec.artifact["sha256"],
            architecture: "x86_64",
            platform: :linux,
            path: "/approved/idle.smolcheckpoint",
            profile: spec.profile
          )

        [checkpoint]
      else
        []
      end

    {:ok, worker} =
      WorkerConfig.new(
        [
          client: client,
          platform: :linux,
          architecture: "x86_64",
          profiles: [spec.profile],
          allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
          capacity: Contract.capacity(Keyword.get(options, :slots, 1)),
          draining: Keyword.get(options, :draining, false),
          artifacts:
            if(checkpoint?,
              do: [],
              else: [Map.put(spec.artifact, "path", "/approved/python.smolmachine")]
            ),
          checkpoints: checkpoints
        ] ++
          case Keyword.fetch(options, :expected_runtime_version) do
            {:ok, version} -> [runtime_version: version]
            :error -> []
          end
      )

    config = [
      name: SmolBox.TestRuntime,
      namespace: "runtest",
      store: store_adapter(store, options),
      mode: :ephemeral,
      fingerprint_key: :binary.copy(<<2>>, 32),
      artifact_store: artifact_adapter(artifacts, options),
      workers: [worker],
      poll_ms: 20,
      lease_ms: 1000,
      max_active: Keyword.get(options, :max_active, 4),
      telemetry_max_pending: Keyword.get(options, :telemetry_max_pending, 128),
      telemetry_timeout_ms: Keyword.get(options, :telemetry_timeout_ms, 100),
      max_pending: Keyword.get(options, :max_pending, 128)
    ]

    runtime = ExUnit.Callbacks.start_supervised!({Runtime, config})

    %{
      runtime: runtime,
      peer: peer,
      store: store,
      artifacts: artifacts,
      spec: spec,
      options: config
    }
  end

  defp artifact_adapter(store, options) do
    if options[:faults],
      do: {SmolBox.FaultArtifacts, %{store: store, faults: options[:faults]}},
      else: {TestArtifacts, store}
  end

  defp store_adapter(store, options) do
    if options[:faults],
      do: {SmolBox.FaultStore, %{store: store, faults: options[:faults]}},
      else: {Memory, store}
  end
end
