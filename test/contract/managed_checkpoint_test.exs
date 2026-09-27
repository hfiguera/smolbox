defmodule SmolBox.ManagedCheckpointTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    CheckpointCaptureSpec,
    CheckpointPolicy,
    Checkpoints,
    Machines,
    ManagedMachineSpec,
    ManagedPeer,
    RuntimeFixture
  }

  alias SmolBox.Store.Memory

  defmodule LegacyStore do
    @moduledoc false
    alias SmolBox.Store.Memory

    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, :managed_checkpoints)}
    end
  end

  test "a store without capture capability rejects opt-in and capture before acceptance" do
    {f, m, s} = fixture()
    stop_supervised!(SmolBox.Runtime)

    runtime =
      start_supervised!({SmolBox.Runtime, Keyword.put(f.options, :store, {LegacyStore, f.store})})

    assert {:error, %{category: :unsupported_capability}} = Checkpoints.capture(runtime, m, s)
    assert {:ok, %{captures: captures, spec: spec}} = Machines.inspect(runtime, m)
    assert captures == %{}

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(runtime, %{spec | id: "another"})

    assert count(f.peer) == 0
  end

  test "capture, durable fetch, explicit resolution, source deletion and artifact release" do
    {f, m, s} = fixture()
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :captured, result: r}} = Checkpoints.await(f.runtime, h, 5000)
    assert r.sha256 == SmolBox.Files.sha256(File.read!(r.path))
    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
    assert {:ok, ^h} = Checkpoints.capture(f.runtime, m, s)

    for action <- [:start, :stop, :delete] do
      {:ok, current} = Machines.inspect(f.runtime, m)
      assert {:error, _} = apply(Machines, action, [f.runtime, m, current.version])
    end

    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:ok, %{state: :captured, result: ^r}} = Checkpoints.fetch(runtime, h)
    {:ok, current} = Machines.inspect(runtime, m)

    assert {:ok, %{state: :completed}} =
             Checkpoints.resolve(runtime, h, current.version, quiesced: true)

    assert {:error, _} = Checkpoints.release(runtime, h, artifacts_removed: true)
    idle = RuntimeFixture.await_idle(runtime, m)
    {:ok, _} = Machines.delete(runtime, m, idle.version)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, m, 5000)
    assert {:ok, %{slots: 0, disk_gb: 1}} = Memory.usage(f.store, "peer")
    File.rm!(r.path)
    assert {:ok, %{released_at_ms: at}} = Checkpoints.release(runtime, h, artifacts_removed: true)
    assert is_integer(at)
    assert {:ok, %{disk_gb: 0}} = Memory.usage(f.store, "peer")
    assert count(f.peer) == 1
    assert {:ok, ^h} = Checkpoints.capture(runtime, m, s)
  end

  test "lost response blocks new work and is never replayed after restart" do
    {f, m, s} = fixture(capture_lost: true)
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :unknown}} = Checkpoints.await(f.runtime, h, 5000)
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:error, _} = Checkpoints.capture(runtime, m, %{s | id: "again"})
    {:ok, current} = Machines.inspect(runtime, m)

    assert {:ok, %{state: :resolved_unknown}} =
             Checkpoints.resolve(runtime, h, current.version, quiesced: true)

    assert count(f.peer) == 1
  end

  test "oversized stream retains unknown outcome and bounded partial evidence" do
    {f, m, s} = fixture(capture_bytes: String.duplicate("a", 8192), max_bytes: 4096)
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :unknown} = r} = Checkpoints.await(f.runtime, h, 5000)
    assert {:ok, stat} = File.stat(SmolBox.CheckpointCapture.path(r) <> ".partial")
    assert stat.size <= 4096
    refute File.exists?(SmolBox.CheckpointCapture.path(r))
  end

  for {field, value} <- [
        {"packed_layers", %{"pack" => "/external.smolmachine"}},
        {"workload", %{"image" => "alpine"}},
        {"credential_ca", %{"key" => "private"}},
        {"network", %{"enabled" => true}},
        {"memory_mib", 512},
        {"host_platform", "darwin/arm64"},
        {"runtime_abi", "unknown"}
      ] do
    test "unsupported captured #{field} retains evidence and blocks reuse" do
      manifest =
        put_in(
          SmolBox.CheckpointFixture.manifest(),
          ["checkpoint", unquote(field)],
          unquote(Macro.escape(value))
        )

      {f, m, s} = fixture(capture_bytes: SmolBox.CheckpointFixture.bytes(manifest))
      {:ok, h} = Checkpoints.capture(f.runtime, m, s)
      assert {:ok, %{state: :unknown, result: nil} = r} = Checkpoints.await(f.runtime, h, 5000)
      assert File.exists?(SmolBox.CheckpointCapture.path(r))
      assert {:error, _} = Checkpoints.capture(f.runtime, m, %{s | id: "again"})
      assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
      assert count(f.peer) == 1
    end
  end

  test "malformed artifact never becomes a reusable result" do
    {f, m, s} = fixture(capture_bytes: "not a checkpoint")
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :unknown, result: nil}} = Checkpoints.await(f.runtime, h, 5000)
  end

  test "ownership mismatch rejects capture before dispatch" do
    {f, m, s} = fixture()

    Agent.update(f.peer, fn state ->
      %{
        state
        | machines:
            Map.new(state.machines, fn {name, r} -> {name, Map.put(r, "createdAt", 9)} end)
      }
    end)

    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :failed}} = Checkpoints.await(f.runtime, h, 5000)
    assert count(f.peer) == 0
  end

  test "conflicting controllers admit only one capture" do
    {f, m, s} = fixture()

    other =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(f.options, :name, SmolBox.OtherCheckpointRuntime)},
        id: :other
      )

    results =
      [{f.runtime, s}, {other, %{s | id: "other"}}]
      |> Task.async_stream(fn {runtime, spec} -> Checkpoints.capture(runtime, m, spec) end)
      |> Enum.map(fn {:ok, r} -> r end)

    assert [{:ok, h}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:ok, %{state: :captured}} = Checkpoints.await(f.runtime, h, 5000)
    assert count(f.peer) == 1
  end

  for {event, phase, expected, requests} <- [
        {:capture_intent, :before, :captured, 1},
        {:capture_intent, :after, :unknown, 0},
        {:capture_result, :before, :unknown, 1},
        {:capture_result, :after, :captured, 1}
      ] do
    test "store failure #{event}/#{phase} preserves uncertainty without replay" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!({Agent, fn -> %{failure: {event, phase}, observer: observer} end},
          id: :failure
        )

      {f, m, s} = fixture(faults: gate)
      {:ok, h} = Checkpoints.capture(f.runtime, m, s)
      assert_receive {:store_failure, ^event, ^phase}, 5000
      assert {:ok, %{state: unquote(expected)}} = Checkpoints.await(f.runtime, h, 5000)
      assert count(f.peer) == unquote(requests)
      assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
    end

    test "restart #{event}/#{phase} retains durable capture evidence" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: event, phase: phase, observer: observer, fired: false} end},
          id: :gate
        )

      {f, m, s} = fixture(faults: gate)
      {:ok, h} = Checkpoints.capture(f.runtime, m, s)
      assert_receive {:boundary, ^event, ^phase, _blocked}, 5000
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, f.options})
      RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
      assert {:ok, %{state: unquote(expected)}} = Checkpoints.await(runtime, h, 5000)
      assert count(f.peer) == unquote(requests)
    end
  end

  for action <- [:cancel, :deadline] do
    test "#{action} cannot turn an in-flight capture into failure" do
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: :capture, phase: :before, observer: observer, fired: false} end},
          id: :gate
        )

      {f, m, s} = fixture(faults: gate)

      {:ok, h} =
        Task.async(fn -> Checkpoints.capture(f.runtime, m, %{s | timeout_ms: 1000}) end)
        |> Task.await()

      assert_receive {:boundary, :capture, :before, blocked}, 5000

      if unquote(action) == :cancel,
        do: assert({:ok, %{state: :unknown}} = Checkpoints.cancel(f.runtime, h))

      assert {:ok, %{state: :unknown}} = Checkpoints.await(f.runtime, h, 3000)
      assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
      send(blocked, :release_boundary)
      assert {:error, _} = Checkpoints.capture(f.runtime, m, %{s | id: "new"})
    end
  end

  test "restore requires a completed result and explicit target-worker approval" do
    {f, m, s} = fixture()
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    {:ok, %{state: :captured, result: result}} = Checkpoints.await(f.runtime, h, 5000)

    {:ok, approval} =
      SmolBox.CheckpointResult.approval(result, id: "copy-source", worker_path: result.path)

    assert {:error, _} =
             Checkpoints.restore(f.runtime, h, approval, scope: "contract", id: "copy")

    {:ok, current} = Machines.inspect(f.runtime, m)
    {:ok, _} = Checkpoints.resolve(f.runtime, h, current.version, quiesced: true)

    assert {:error, %{category: :unsupported_capability}} =
             Checkpoints.restore(f.runtime, h, approval, scope: "contract", id: "copy")

    stop_supervised!(SmolBox.Runtime)

    options =
      Keyword.update!(f.options, :workers, fn workers ->
        Enum.map(workers, &%{&1 | checkpoints: [approval]})
      end)

    runtime = start_supervised!({SmolBox.Runtime, options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)

    assert {:error, _} =
             Checkpoints.restore(runtime, h, %{approval | sha256: String.duplicate("b", 64)},
               scope: "contract",
               id: "copy"
             )

    assert {:error, _} =
             Checkpoints.restore(runtime, h, approval, scope: elem(m, 0), id: elem(m, 1))

    assert {:ok, {"contract", "copy"} = child} =
             Checkpoints.restore(runtime, h, approval, scope: "contract", id: "copy")

    assert {:ok, %{state: :created}} = Machines.await(runtime, child, 5000)

    assert {:ok, ^child} =
             Checkpoints.restore(runtime, h, approval, scope: "contract", id: "copy")

    assert count(f.peer) == 1
  end

  test "active command blocks capture; unsupported opt-in and idle declarations fail validation" do
    observer = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: :exec, phase: :before, observer: observer, fired: false} end},
        id: :gate
      )

    {f, m, s} = fixture(faults: gate)
    {:ok, execution} = Machines.submit(f.runtime, m, f.spec)
    assert_receive {:boundary, :exec, :before, blocked}, 5000
    assert {:error, _} = Checkpoints.capture(f.runtime, m, s)
    assert {:error, _} = Checkpoints.capture(f.runtime, m, %{s | idle: false})
    send(blocked, :release_boundary)
    assert {:ok, %{state: :completed}} = SmolBox.await(f.runtime, execution, 5000)
    assert count(f.peer) == 0
  end

  test "verified absence resolves a quiescent capture while retaining artifact accounting" do
    {f, m, s} = fixture(capture_lost: true)
    {:ok, h} = Checkpoints.capture(f.runtime, m, s)
    assert {:ok, %{state: :unknown}} = Checkpoints.await(f.runtime, h, 5000)
    {:ok, current} = Machines.inspect(f.runtime, m)

    assert {:error, _} =
             Checkpoints.resolve(f.runtime, h, current.version,
               quiesced: true,
               disposition: :deleted
             )

    Agent.update(f.peer, &%{&1 | machines: %{}})
    {:ok, current} = Machines.inspect(f.runtime, m)

    assert {:ok, %{state: :resolved_unknown}} =
             Checkpoints.resolve(f.runtime, h, current.version,
               quiesced: true,
               disposition: :deleted
             )

    assert {:ok, %{state: :deleted, reservation: nil}} = Machines.inspect(f.runtime, m)
    assert {:ok, %{slots: 0, disk_gb: 1}} = Memory.usage(f.store, "peer")
  end

  defp fixture(options \\ []) do
    root = Path.join(System.tmp_dir!(), "smolbox-capture-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "test",
        root: root,
        max_bytes: Keyword.get(options, :max_bytes, 1_048_576),
        resources: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 16}
      )

    f =
      RuntimeFixture.start(
        __MODULE__,
        options ++
          [
            capture: true,
            checkpoint_policies: [policy],
            capacity: %{slots: 4, cpus: 8, memory_mb: 8192, disk_gb: 128}
          ]
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "capture",
        artifact: f.spec.artifact,
        profile: f.spec.profile,
        checkpointable: true
      )

    {:ok, m} = Machines.create(f.runtime, spec)
    {:ok, _} = Machines.await(f.runtime, m, 5000)
    idle = RuntimeFixture.await_idle(f.runtime, m)
    {:ok, _} = Machines.start(f.runtime, m, idle.version)
    {:ok, %{state: :running}} = Machines.await(f.runtime, m, 5000)
    RuntimeFixture.await_idle(f.runtime, m)
    {:ok, s} = CheckpointCaptureSpec.new(id: "one", policy: policy, idle: true)
    {f, m, s}
  end

  defp count(peer),
    do:
      Enum.count(ManagedPeer.snapshot(peer).operations, fn {method, path} ->
        method == "POST" and String.ends_with?(path, "/checkpoint")
      end)
end
