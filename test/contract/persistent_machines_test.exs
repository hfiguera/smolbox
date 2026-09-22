defmodule SmolBox.PersistentMachinesTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Error, Machines, ManagedMachineSpec, ManagedPeer, RuntimeFixture}
  alias SmolBox.Store.Memory

  test "commands retain their machine, stop/start preserves files, and explicit delete releases capacity" do
    fixture = RuntimeFixture.start()
    handle = create(fixture)
    created = wait_machine(fixture, handle, &(&1.state == :created))
    assert {:ok, ^handle} = Machines.create(fixture.runtime, created.spec)
    assert {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    running = wait_machine(fixture, handle, &(&1.state == :running))
    assert running.reservation.slots == 1

    for id <- ["first", "second"] do
      spec = %{fixture.spec | id: id}
      assert {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)
      assert {:ok, ^execution} = Machines.submit(fixture.runtime, handle, spec)

      assert {:ok, %{state: :completed, result: %{exit_code: 7}}} =
               SmolBox.await(fixture.runtime, execution, 5000)

      wait_machine(fixture, handle, &is_nil(&1.active_execution))
      assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
      assert map_size(ManagedPeer.snapshot(fixture.peer).machines) == 1
    end

    {:ok, idle} = Machines.inspect(fixture.runtime, handle)
    assert {:ok, stop} = Machines.stop(fixture.runtime, handle, idle.version)
    assert {:ok, duplicate} = Machines.stop(fixture.runtime, handle, idle.version)
    assert duplicate.last_request == stop.last_request
    stopped = wait_machine(fixture, handle, &(&1.state == :stopped))
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.submit(fixture.runtime, handle, %{fixture.spec | id: "stopped"})

    assert {:ok, _} = Machines.start(fixture.runtime, handle, stopped.version)
    running = wait_machine(fixture, handle, &(&1.state == :running))

    assert ManagedPeer.snapshot(fixture.peer).files[
             {running.machine_name, ["workspace", "out.bin"]}
           ] == <<0, 255, 17>>

    assert {:ok, _} = Machines.delete(fixture.runtime, handle, running.version)
    deleted = wait_machine(fixture, handle, &(&1.state == :deleted))
    assert deleted.absence_at_ms != nil
    assert deleted.reservation == nil
    assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
    assert ManagedPeer.snapshot(fixture.peer).machines == %{}
    assert {:ok, ^handle} = Machines.create(fixture.runtime, created.spec)
  end

  test "active and unknown commands block commands and lifecycle operations without deleting" do
    fixture = RuntimeFixture.start(hold: true)
    handle = create(fixture)
    created = wait_machine(fixture, handle, &(&1.state == :created))
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    wait_machine(fixture, handle, &(&1.state == :running))
    {:ok, execution} = Machines.submit(fixture.runtime, handle, fixture.spec)
    wait_execution(fixture, execution, &(&1.state == :running))
    {:ok, busy} = Machines.inspect(fixture.runtime, handle)

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.stop(fixture.runtime, handle, busy.version)

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.delete(fixture.runtime, handle, busy.version)

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.submit(fixture.runtime, handle, %{fixture.spec | id: "another"})

    assert {:ok, _} = SmolBox.cancel(fixture.runtime, elem(execution, 0), elem(execution, 1))
    assert {:ok, %{state: :unknown}} = SmolBox.await(fixture.runtime, execution, 5000)
    wait_machine(fixture, handle, &(&1.state == :unknown))
    snapshot = ManagedPeer.snapshot(fixture.peer)
    assert map_size(snapshot.machines) == 1

    refute Enum.any?(snapshot.operations, fn {method, path} ->
             method == "DELETE" or String.ends_with?(path, "/stop")
           end)

    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
  end

  test "lost creation response retains ownership uncertainty without adopting or recreating" do
    fixture = RuntimeFixture.start(create_lost: true)
    handle = create(fixture)
    unknown = wait_machine(fixture, handle, &(&1.state == :unknown))
    assert unknown.created_machine == nil
    assert unknown.reservation != nil
    assert {:error, _} = Machines.submit(fixture.runtime, handle, fixture.spec)

    assert [_creation] =
             Enum.filter(
               ManagedPeer.snapshot(fixture.peer).operations,
               &(&1 == {"POST", "/api/v1/machines"})
             )
  end

  test "controller restart reconnects to the same idle machine" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture)
    {:ok, original} = Machines.inspect(fixture.runtime, handle)
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    fixture = %{fixture | runtime: runtime}
    {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.machine_name == original.machine_name
    {:ok, execution} = Machines.submit(runtime, handle, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000)
    wait_machine(fixture, handle, &is_nil(&1.active_execution))
    assert map_size(ManagedPeer.snapshot(fixture.peer).machines) == 1
  end

  test "restart after persisted dispatch intent cannot replay and blocks later commands" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :dispatch_intent, phase: :after, fired: false, observer: observer} end},
        id: :gate
      )

    fixture = RuntimeFixture.start(faults: gate)
    handle = start_machine(fixture)
    {:ok, execution} = Machines.submit(fixture.runtime, handle, fixture.spec)
    assert_receive {:boundary, :dispatch_intent, :after, _blocked}, 5000
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    fixture = %{fixture | runtime: runtime}
    assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, execution, 5000)
    wait_machine(fixture, handle, &(&1.state == :unknown))
    assert ManagedPeer.snapshot(fixture.peer).commands == []
    assert {:error, _} = Machines.submit(runtime, handle, %{fixture.spec | id: "later"})
  end

  test "restart during collection preserves the known exit and blocks reuse without replaying file requests" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :result_write, phase: :after, fired: false, observer: observer} end},
        id: :gate
      )

    fixture = RuntimeFixture.start(faults: gate)
    handle = start_machine(fixture)

    spec = %{
      fixture.spec
      | outputs: [%{"destination" => "output", "path" => "/workspace/out.bin", "max_bytes" => 32}]
    }

    {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)
    assert_receive {:boundary, :result_write, :after, _blocked}, 5000
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    fixture = %{fixture | runtime: runtime}

    assert {:ok, %{state: :collection_failed, result: %{exit_code: 7}}} =
             SmolBox.await(runtime, execution, 5000)

    wait_machine(fixture, handle, &(&1.state == :unknown))
    assert [_command] = ManagedPeer.snapshot(fixture.peer).commands
    assert {:error, _} = Machines.submit(runtime, handle, %{fixture.spec | id: "later"})
  end

  test "failed stop stays blocked; explicit quiescent resolution preserves the machine" do
    fixture = RuntimeFixture.start(stop_failure: true)
    handle = start_machine(fixture)
    {:ok, idle} = Machines.inspect(fixture.runtime, handle)
    {:ok, _} = Machines.stop(fixture.runtime, handle, idle.version)
    blocked = wait_machine(fixture, handle, &(&1.state == :unknown))

    assert {:error, _} =
             Machines.resolve(fixture.runtime, handle, blocked.version, quiesced: true)

    Agent.update(fixture.peer, fn state ->
      put_in(state.machines[blocked.machine_name]["state"], "stopped")
    end)

    {:ok, current} = Machines.inspect(fixture.runtime, handle)

    assert {:error, %{category: :stale_version}} =
             Machines.resolve(fixture.runtime, handle, current.version - 1, quiesced: true)

    assert {:ok, resolved} =
             Machines.resolve(fixture.runtime, handle, current.version, quiesced: true)

    assert resolved.state == :stopped and resolved.reservation != nil and
             resolved.resolved_at_ms != nil

    assert [_stop] =
             Enum.filter(ManagedPeer.snapshot(fixture.peer).operations, fn {_method, path} ->
               String.ends_with?(path, "/stop")
             end)
  end

  test "lost delete acknowledgment reconciles absence without issuing another delete" do
    fixture = RuntimeFixture.start(delete_lost: true)
    handle = start_machine(fixture)
    {:ok, idle} = Machines.inspect(fixture.runtime, handle)
    {:ok, _} = Machines.delete(fixture.runtime, handle, idle.version)
    wait_machine(fixture, handle, &(&1.state == :unknown))
    assert :ok = Machines.reconcile(fixture.runtime, handle)
    gone = wait_machine(fixture, handle, &(&1.state == :deleted))
    assert gone.reservation == nil and gone.absence_at_ms != nil

    assert [_delete] =
             Enum.filter(
               ManagedPeer.snapshot(fixture.peer).operations,
               &(elem(&1, 0) == "DELETE")
             )
  end

  test "missing machines are not replaced and require explicit quiescent absence resolution" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture)
    Agent.update(fixture.peer, &%{&1 | machines: %{}})
    assert :ok = Machines.reconcile(fixture.runtime, handle)
    missing = wait_machine(fixture, handle, &(&1.state == :missing))
    assert missing.reservation != nil
    assert {:error, _} = Machines.submit(fixture.runtime, handle, fixture.spec)

    assert {:ok, gone} =
             Machines.resolve(fixture.runtime, handle, missing.version,
               quiesced: true,
               disposition: :deleted
             )

    assert gone.state == :deleted and gone.reservation == nil

    assert [_creation] =
             Enum.filter(
               ManagedPeer.snapshot(fixture.peer).operations,
               &(&1 == {"POST", "/api/v1/machines"})
             )
  end

  test "ownership mismatch prevents lifecycle mutation" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture)
    {:ok, idle} = Machines.inspect(fixture.runtime, handle)

    Agent.update(fixture.peer, fn state ->
      update_in(state.machines[idle.machine_name]["createdAt"], &(&1 + 10))
    end)

    {:ok, _} = Machines.delete(fixture.runtime, handle, idle.version)
    conflict = wait_machine(fixture, handle, &(&1.state == :conflict))
    assert conflict.reservation != nil
    refute Enum.any?(ManagedPeer.snapshot(fixture.peer).operations, &(elem(&1, 0) == "DELETE"))
  end

  test "unavailable store cannot be mistaken for a missing machine" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture)
    stop_supervised!(Memory)
    assert {:error, %{category: :store}} = Machines.inspect(fixture.runtime, handle)
    assert {:error, %{category: :store}} = Machines.submit(fixture.runtime, handle, fixture.spec)

    assert [_creation] =
             Enum.filter(
               ManagedPeer.snapshot(fixture.peer).operations,
               &(&1 == {"POST", "/api/v1/machines"})
             )
  end

  test "queued creation can be deleted without worker allocation and await has independent timeout" do
    fixture = RuntimeFixture.start(draining: true)
    handle = create(fixture)
    assert {:error, %{category: :expired}} = Machines.await(fixture.runtime, handle, 0)
    assert {:error, %{category: :validation}} = Machines.await(fixture.runtime, handle, -1)

    assert {:error, %{category: :validation}} =
             Machines.list(fixture.runtime, "contract", unexpected: true)

    {:ok, queued} = Machines.inspect(fixture.runtime, handle)
    assert {:ok, %{state: :deleted}} = Machines.delete(fixture.runtime, handle, queued.version)

    assert {:ok, %{state: :deleted, reservation: nil}} =
             Machines.await(fixture.runtime, handle, 0)

    assert ManagedPeer.snapshot(fixture.peer).machines == %{}
    assert {:ok, [deleted], nil} = Machines.list(fixture.runtime, "contract")
    assert deleted.state == :deleted
  end

  defp start_machine(fixture) do
    handle = create(fixture)
    created = wait_machine(fixture, handle, &(&1.state == :created))
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    wait_machine(fixture, handle, &(&1.state == :running))
    handle
  end

  defp create(fixture) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "computer",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile
      )

    assert {:ok, handle} = Machines.create(fixture.runtime, spec)
    handle
  end

  defp wait_machine(fixture, handle, predicate),
    do: wait(fn -> Machines.inspect(fixture.runtime, handle) end, predicate)

  defp wait_execution(fixture, {scope, id}, predicate),
    do: wait(fn -> SmolBox.fetch(fixture.runtime, scope, id) end, predicate)

  defp wait(fetch, predicate),
    do: wait(fetch, predicate, System.monotonic_time(:millisecond) + 5000)

  defp wait(fetch, predicate, deadline) do
    {:ok, record} = fetch.()

    if predicate.(record) do
      record
    else
      assert System.monotonic_time(:millisecond) < deadline, "timed out: #{inspect(record)}"
      Process.sleep(20)
      wait(fetch, predicate, deadline)
    end
  end
end
