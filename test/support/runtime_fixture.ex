defmodule SmolBox.RuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions, only: [assert: 2]
  alias SmolBox.{Client, ManagedPeer, Runtime, TestArtifacts, Worker}
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.{Contract, Memory}

  # Use the test module as the registered name so modules can run concurrently.
  # Each fixture still owns its store, peer, and artifacts; restarts reuse this name.
  def start(name, options \\ []) when is_atom(name) do
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
      name: name,
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

  # Machine idle state can precede the scheduler's final claim/write. Tests
  # issuing a versioned lifecycle request must wait for that work as well.
  def await_idle(runtime, handle, deadline \\ System.monotonic_time(:millisecond) + 5000) do
    coordinator = :sys.get_state(Runtime.coordinator(runtime))
    {:ok, machine} = SmolBox.Machines.inspect(runtime, handle)

    if coordinator.active == %{} and coordinator.scan == nil and
         machine.active_execution == nil and machine.operation == nil and
         machine.next_due_at_ms > System.system_time(:millisecond) do
      machine
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "machine did not become quiescent: #{inspect({machine, coordinator.active, coordinator.scan})}"

      Process.sleep(5)
      await_idle(runtime, handle, deadline)
    end
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
