defmodule SmolBox.LocalVolumesTest do
  use ExUnit.Case, async: true
  alias SmolBox.Store.Contract

  alias SmolBox.{
    Machines,
    ManagedMachineSpec,
    Runtime,
    RuntimeFixture,
    Volume,
    VolumeMount,
    VolumePolicy,
    Volumes
  }

  alias SmolBox.Store.Memory

  defp fixture(options \\ []) do
    {:ok, policy} = VolumePolicy.new("local", "/approved/volumes")

    RuntimeFixture.start(
      __MODULE__,
      [volume_policy: policy, capacity: Contract.capacity(10)] ++ options
    )
  end

  defp create(f, id \\ "data") do
    options = [scope: f.spec.scope, id: id, worker_id: "peer", size_gb: 2]
    assert {:ok, handle} = Volumes.create(f.runtime, options)
    {handle, options}
  end

  defp machine(f, id, volume) do
    {:ok, mount} = VolumeMount.new(volume, "/mnt/volumes/data")

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: id,
        artifact: f.spec.artifact,
        profile: f.spec.profile,
        volumes: [mount]
      )

    Machines.create(f.runtime, spec)
  end

  defp delete_machine(f, handle) do
    m = RuntimeFixture.await_idle(f.runtime, handle)
    assert {:ok, _} = Machines.delete(f.runtime, handle, m.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, handle, 5000)
  end

  test "volume survives machine deletion and controller restart; attachments remain exclusive while stopped" do
    f = fixture()
    {volume, options} = create(f)
    assert {:ok, %{state: :ready}} = Volumes.inspect(f.runtime, volume)
    assert {:ok, ^volume} = Volumes.create(f.runtime, options)
    assert {:ok, a} = machine(f, "first", "data")
    m = RuntimeFixture.await_idle(f.runtime, a)
    assert [%{source: source, target: "/mnt/volumes/data"}] = m.created_machine.mounts
    assert {:error, %{category: :admission_exhausted}} = machine(f, "competing", "data")
    {:ok, held} = Volumes.inspect(f.runtime, volume)
    assert held.attached_to == a and source == Volume.path(held)

    assert {:error, %{category: :admission_exhausted}} =
             Volumes.delete(f.runtime, volume, held.version)

    {:ok, _} = Machines.start(f.runtime, a, m.version)
    RuntimeFixture.await_idle(f.runtime, a)
    assert {:ok, command} = Machines.submit(f.runtime, a, %{f.spec | id: "mounted-command"})
    assert {:ok, %{state: :completed}} = SmolBox.await(f.runtime, command, 5000)
    running = RuntimeFixture.await_idle(f.runtime, a)
    {:ok, _} = Machines.stop(f.runtime, a, running.version)
    RuntimeFixture.await_idle(f.runtime, a)
    assert {:error, %{category: :admission_exhausted}} = machine(f, "competing", "data")
    delete_machine(f, a)
    assert {:ok, %{disk_gb: 2}} = Memory.usage(f.store, "peer")
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 30_000)
    f = %{f | runtime: runtime}
    assert {:ok, b} = machine(f, "replacement", "data")
    replacement = RuntimeFixture.await_idle(runtime, b)
    assert hd(replacement.created_machine.mounts).source == source

    assert {:ok, %{assessment: :blocked, records: entries}} =
             SmolBox.worker_maintenance(runtime, "peer")

    assert Enum.any?(entries, &(&1.kind == :volume))
    delete_machine(f, b)
    {:ok, free} = Volumes.inspect(runtime, volume)
    assert {:ok, %{state: :deleted}} = Volumes.delete(runtime, volume, free.version)
    assert {:ok, %{disk_gb: 0}} = Memory.usage(f.store, "peer")
    assert {:ok, ^volume} = Volumes.create(runtime, options)
    assert {:ok, [%{state: :deleted}], nil} = Volumes.list(runtime, f.spec.scope)
  end

  test "uncertain provisioning is retained without replay; explicit fenced cleanup verifies deletion" do
    f = fixture(volume_create_lost: true)
    {volume, options} = create(f)
    {:ok, unknown} = Volumes.inspect(f.runtime, volume)
    assert unknown.state == :unknown
    assert {:ok, ^volume} = Volumes.create(f.runtime, options)
    assert {:error, _} = machine(f, "unsafe", "data")
    assert {:error, _} = Volumes.delete(f.runtime, volume, unknown.version)

    assert {:error, _} =
             Volumes.resolve_delete(f.runtime, volume, unknown.version, quiesced: false)

    assert {:ok, %{disk_gb: 2}} = Memory.usage(f.store, "peer")

    assert {:ok, %{state: :deleted}} =
             Volumes.resolve_delete(f.runtime, volume, unknown.version, quiesced: true)

    assert Enum.count(
             SmolBox.ManagedPeer.snapshot(f.peer).operations,
             &(&1 == {"POST", "/api/v1/volumes"})
           ) == 1
  end

  test "drain blocks new volumes and attachments, but allows existing volume deletion" do
    f = fixture()
    {volume, options} = create(f)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")
    assert {:ok, ^volume} = Volumes.create(f.runtime, options)

    assert {:error, %{category: :admission_exhausted}} =
             Volumes.create(f.runtime, Keyword.put(options, :id, "new"))

    assert {:error, %{category: :admission_exhausted}} = machine(f, "blocked", "data")
    {:ok, free} = Volumes.inspect(f.runtime, volume)
    assert free.attached_to == nil
    assert {:ok, %{state: :deleted}} = Volumes.delete(f.runtime, volume, free.version)
  end

  test "lost deletion response holds accounting and duplicate deletion does not replay" do
    f = fixture(volume_delete_lost: true)
    {volume, _} = create(f)
    {:ok, ready} = Volumes.inspect(f.runtime, volume)
    assert {:ok, %{state: :unknown}} = Volumes.delete(f.runtime, volume, ready.version)
    assert {:ok, %{state: :unknown}} = Volumes.delete(f.runtime, volume, ready.version)
    assert {:ok, %{disk_gb: 2}} = Memory.usage(f.store, "peer")

    assert Enum.count(SmolBox.ManagedPeer.snapshot(f.peer).operations, fn {method, path} ->
             method == "DELETE" and String.contains?(path, "/volumes/")
           end) == 1
  end

  for {event, phase, expected, calls} <- [
        {:volume_accept, :before, :absent, 0},
        {:volume_accept, :after, :creating, 0},
        {:volume_change, :before, :creating, 1},
        {:volume_change, :after, :ready, 1}
      ] do
    test "store failure #{event}/#{phase} retains evidence without automatic replay" do
      observer = self()
      event = unquote(event)
      phase = unquote(phase)

      gate =
        start_supervised!({Agent, fn -> %{failure: {event, phase}, observer: observer} end},
          id: :failure
        )

      f = fixture(faults: gate)
      options = [scope: f.spec.scope, id: "failure", worker_id: "peer", size_gb: 2]
      assert {:error, %{category: :store}} = Volumes.create(f.runtime, options)
      assert_receive {:store_failure, ^event, ^phase}
      key = {f.spec.scope, "failure"}

      case unquote(expected) do
        :absent ->
          assert {:error, %{category: :not_found}} = Volumes.inspect(f.runtime, key)

        state ->
          assert {:ok, %{state: ^state}} = Volumes.inspect(f.runtime, key)
          assert {:ok, ^key} = Volumes.create(f.runtime, options)
          assert {:ok, %{disk_gb: 2}} = Memory.usage(f.store, "peer")
      end

      assert provision_count(f) == unquote(calls)
    end
  end

  test "caller death after provisioning preserves pending identity across controller restart" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :volume_change, phase: :before, observer: observer, fired: false} end},
        id: :gate
      )

    f = fixture(faults: gate)
    options = [scope: f.spec.scope, id: "interrupted", worker_id: "peer", size_gb: 2]
    caller = spawn(fn -> Volumes.create(f.runtime, options) end)
    assert_receive {:boundary, :volume_change, :before, ^caller}, 5000
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, f.options})
    assert {:ok, key} = Volumes.create(runtime, options)
    assert {:ok, %{state: :creating}} = Volumes.inspect(runtime, key)
    assert provision_count(f) == 1
    assert {:error, _} = machine(%{f | runtime: runtime}, "unsafe", "interrupted")
  end

  test "changed mount observations do not authorize deletion or attachment release" do
    f = fixture()
    {volume, _} = create(f)
    {:ok, handle} = machine(f, "ownership", "data")
    m = RuntimeFixture.await_idle(f.runtime, handle)

    Agent.update(f.peer, fn state ->
      update_in(state, [:machines, m.machine_name, "mounts"], fn [mount] ->
        [Map.put(mount, "source", "/someone/elses/data")]
      end)
    end)

    assert {:ok, _} = Machines.delete(f.runtime, handle, m.version)
    assert {:ok, %{state: state}} = Machines.await(f.runtime, handle, 5000)
    refute state == :deleted
    assert {:ok, %{attached_to: ^handle}} = Volumes.inspect(f.runtime, volume)

    refute Enum.any?(
             SmolBox.ManagedPeer.snapshot(f.peer).operations,
             &(&1 == {"DELETE", "/api/v1/machines/" <> m.machine_name})
           )
  end

  test "revoked root blocks a restart and preserves attachment evidence" do
    f = fixture()
    {volume, _} = create(f)
    {:ok, handle} = machine(f, "revoked", "data")
    m = RuntimeFixture.await_idle(f.runtime, handle)
    stop_supervised!(Runtime)
    [worker] = f.options[:workers]
    {:ok, policy} = VolumePolicy.new("new-root", "/other/volumes")
    options = Keyword.put(f.options, :workers, [%{worker | volume_policy: policy}])
    runtime = start_supervised!({Runtime, options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 30_000)
    current = RuntimeFixture.await_idle(runtime, handle)
    assert {:ok, _} = Machines.start(runtime, handle, current.version)
    blocked = await_policy_block(runtime, handle, System.monotonic_time(:millisecond) + 5000)
    assert blocked.phase == :pending

    refute Enum.any?(
             SmolBox.ManagedPeer.snapshot(f.peer).operations,
             &(&1 == {"POST", "/api/v1/machines/" <> m.machine_name <> "/start"})
           )

    assert {:ok, %{attached_to: ^handle}} = Volumes.inspect(runtime, volume)
    # A rejected dispatch keeps the pending intent and attachment; it cannot imply deletion.
    assert {:ok, %{disk_gb: disk}} = Memory.usage(f.store, "peer")
    assert disk > 2
  end

  test "configuration draining rejects new volumes and attachments but preserves duplicate lookup and cleanup" do
    f = fixture()
    {volume, options} = create(f)
    stop_supervised!(Runtime)
    [worker] = f.options[:workers]

    runtime =
      start_supervised!({Runtime, Keyword.put(f.options, :workers, [%{worker | draining: true}])})

    assert {:ok, ^volume} = Volumes.create(runtime, options)

    assert {:error, %{category: :admission_exhausted}} =
             Volumes.create(runtime, Keyword.put(options, :id, "new"))

    assert {:error, %{category: :admission_exhausted}} =
             machine(%{f | runtime: runtime}, "blocked", "data")

    {:ok, ready} = Volumes.inspect(runtime, volume)
    assert {:ok, %{state: :deleted}} = Volumes.delete(runtime, volume, ready.version)
    assert provision_count(f) == 1
  end

  defp await_policy_block(runtime, handle, deadline) do
    {:ok, record} = Machines.inspect(runtime, handle)

    case record.last_error do
      %{category: :unsupported_capability} ->
        record

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(10)
        await_policy_block(runtime, handle, deadline)
    end
  end

  defp provision_count(f),
    do:
      Enum.count(
        SmolBox.ManagedPeer.snapshot(f.peer).operations,
        &(&1 == {"POST", "/api/v1/volumes"})
      )
end
