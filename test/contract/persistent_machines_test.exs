defmodule SmolBox.PersistentMachinesTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Error, Machines, ManagedMachineSpec, ManagedPeer, RuntimeFixture}
  alias SmolBox.Store.Codec
  alias SmolBox.Store.Memory

  defmodule LegacyStore do
    @moduledoc false
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.drop(capabilities, [:managed_ports, :extended_execution])}
    end
  end

  for mappings <- [[], [%SmolBox.PortMapping{host: 28_731, guest: 8000}]] do
    @mappings mappings
    test "commands retain their machine, stop/start preserves files, and explicit delete releases capacity (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start()
      handle = create(fixture, @mappings)
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
      assert deleted.reservation == nil and deleted.reserved_ports == []
      assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
      assert ManagedPeer.snapshot(fixture.peer).machines == %{}
      assert {:ok, ^handle} = Machines.create(fixture.runtime, created.spec)
    end

    test "active and unknown commands block commands and lifecycle operations without deleting (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start(hold: true)
      handle = create(fixture, @mappings)
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

    test "lost creation response retains ownership uncertainty without adopting or recreating (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start(create_lost: true)
      handle = create(fixture, @mappings)
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

    test "controller restart reconnects to the same idle machine (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start()
      handle = start_machine(fixture, @mappings)
      {:ok, original} = Machines.inspect(fixture.runtime, handle)
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, fixture.options})
      fixture = %{fixture | runtime: runtime}
      {:ok, recovered} = Machines.inspect(runtime, handle)
      assert recovered.machine_name == original.machine_name
      assert recovered.spec.ports == @mappings
      assert recovered.reserved_ports == Enum.map(@mappings, & &1.host)
      {:ok, execution} = Machines.submit(runtime, handle, fixture.spec)
      assert {:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000)
      wait_machine(fixture, handle, &is_nil(&1.active_execution))
      assert map_size(ManagedPeer.snapshot(fixture.peer).machines) == 1
    end

    test "restart after persisted dispatch intent cannot replay and blocks later commands (ports=#{inspect(@mappings)})" do
      observer = self()

      gate =
        start_supervised!(
          {Agent,
           fn -> %{event: :dispatch_intent, phase: :after, fired: false, observer: observer} end},
          id: :gate
        )

      fixture = RuntimeFixture.start(faults: gate)
      handle = start_machine(fixture, @mappings)
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

    test "restart during collection preserves the known exit and blocks reuse without replaying file requests (ports=#{inspect(@mappings)})" do
      observer = self()

      gate =
        start_supervised!(
          {Agent,
           fn -> %{event: :result_write, phase: :after, fired: false, observer: observer} end},
          id: :gate
        )

      fixture = RuntimeFixture.start(faults: gate)
      handle = start_machine(fixture, @mappings)

      spec = %{
        fixture.spec
        | outputs: [
            %{"destination" => "output", "path" => "/workspace/out.bin", "max_bytes" => 32}
          ]
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

    test "failed stop stays blocked; explicit quiescent resolution preserves the machine (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start(stop_failure: true)
      handle = start_machine(fixture, @mappings)
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

    test "lost delete acknowledgment reconciles absence without issuing another delete (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start(delete_lost: true)
      handle = start_machine(fixture, @mappings)
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

    test "missing machines are not replaced and require explicit quiescent absence resolution (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start()
      handle = start_machine(fixture, @mappings)
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

    test "ownership mismatch prevents lifecycle mutation (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start()
      handle = start_machine(fixture, @mappings)
      {:ok, idle} = Machines.inspect(fixture.runtime, handle)

      Agent.update(fixture.peer, fn state ->
        update_in(state.machines[idle.machine_name]["createdAt"], &(&1 + 10))
      end)

      {:ok, _} = Machines.delete(fixture.runtime, handle, idle.version)
      conflict = wait_machine(fixture, handle, &(&1.state == :conflict))
      assert conflict.reservation != nil
      refute Enum.any?(ManagedPeer.snapshot(fixture.peer).operations, &(elem(&1, 0) == "DELETE"))
    end

    test "unavailable store cannot be mistaken for a missing machine (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start()
      handle = start_machine(fixture, @mappings)
      stop_supervised!(Memory)
      assert {:error, %{category: :store}} = Machines.inspect(fixture.runtime, handle)

      assert {:error, %{category: :store}} =
               Machines.submit(fixture.runtime, handle, fixture.spec)

      assert [_creation] =
               Enum.filter(
                 ManagedPeer.snapshot(fixture.peer).operations,
                 &(&1 == {"POST", "/api/v1/machines"})
               )
    end

    test "queued creation can be deleted without worker allocation and await has independent timeout (ports=#{inspect(@mappings)})" do
      fixture = RuntimeFixture.start(draining: true)
      handle = create(fixture, @mappings)
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
  end

  test "store port conflicts remain unassigned and cannot silently retry on another worker" do
    fixture = RuntimeFixture.start(slots: 2)
    mappings = [%SmolBox.PortMapping{host: 28_731, guest: 8000}]
    handle = start_machine(fixture, mappings)
    {:ok, owner} = Machines.inspect(fixture.runtime, handle)
    {:ok, contender} = Machines.create(fixture.runtime, %{owner.spec | id: "contender"})
    conflict = wait_machine(fixture, contender, &(&1.state == :conflict))
    assert conflict.last_error.category == :port_conflict
    assert conflict.worker_id == nil and conflict.reserved_ports == []
    {:ok, _} = Machines.delete(fixture.runtime, handle, owner.version)
    wait_machine(fixture, handle, &(&1.state == :deleted))
    assert :ok = Machines.reconcile(fixture.runtime, contender)

    wait_machine(
      fixture,
      contender,
      &(&1.next_due_at_ms > System.system_time(:millisecond) + 30_000)
    )

    {:ok, still_blocked} = Machines.await(fixture.runtime, contender, 5000)
    assert still_blocked.state == :conflict

    assert {:ok, %{state: :deleted}} =
             Machines.delete(fixture.runtime, contender, still_blocked.version)

    assert 1 ==
             Enum.count(
               ManagedPeer.snapshot(fixture.peer).operations,
               &(&1 == {"POST", "/api/v1/machines"})
             )
  end

  test "changed observed mappings prohibit delete even when name and creation timestamp match" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
    {:ok, original} = Machines.inspect(fixture.runtime, handle)

    Agent.update(fixture.peer, fn state ->
      put_in(state.machines[original.machine_name]["ports"], [
        %{"host" => 28_731, "guest" => 8001}
      ])
    end)

    {:ok, _} = Machines.delete(fixture.runtime, handle, original.version)
    conflict = wait_machine(fixture, handle, &(&1.state == :conflict))
    assert conflict.reserved_ports == [28_731]
    refute Enum.any?(ManagedPeer.snapshot(fixture.peer).operations, &(elem(&1, 0) == "DELETE"))
  end

  test "downgrading a store capability blocks mapped recovery and command admission" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
    {:ok, original} = Machines.inspect(fixture.runtime, handle)
    stop_supervised!(SmolBox.Runtime)
    snapshot = ManagedPeer.snapshot(fixture.peer)
    options = Keyword.put(fixture.options, :store, {LegacyStore, fixture.store})
    runtime = start_supervised!({SmolBox.Runtime, options})

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(runtime, original.spec)

    assert {:error, %{category: :unsupported_capability}} =
             Machines.submit(runtime, handle, fixture.spec)

    assert {:error, %{category: :unsupported_capability}} =
             Machines.stop(runtime, handle, original.version)

    assert :ok = Machines.reconcile(runtime, handle)
    # Worker health reads are allowed; recovery cannot mutate the mapped machine.
    Process.sleep(100)
    operations = ManagedPeer.snapshot(fixture.peer).operations -- snapshot.operations
    refute Enum.any?(operations, fn {method, _path} -> method in ["POST", "PUT", "DELETE"] end)
    assert {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.reserved_ports == [28_731]

    assert {:ok, _} =
             Machines.create(runtime, %{original.spec | id: "legacy-no-ports", ports: []})
  end

  test "a dispatched port conflict retains ownership until explicit quiescent resolution" do
    fixture = RuntimeFixture.start(start_port_conflict: true)
    handle = create(fixture, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
    created = wait_machine(fixture, handle, &(&1.state == :created))
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    blocked = wait_machine(fixture, handle, &(&1.state == :unknown))
    assert blocked.last_error.category == :port_conflict
    assert blocked.reserved_ports == [28_731] and blocked.reservation != nil
    assert {:error, _} = Machines.submit(fixture.runtime, handle, fixture.spec)

    assert 1 ==
             Enum.count(ManagedPeer.snapshot(fixture.peer).operations, fn {method, path} ->
               method == "POST" and String.ends_with?(path, "/start")
             end)

    Agent.update(
      fixture.peer,
      &%{&1 | options: Keyword.put(&1.options, :start_port_conflict, false)}
    )

    assert {:ok, resolved} =
             Machines.resolve(fixture.runtime, handle, blocked.version, quiesced: true)

    assert resolved.reserved_ports == [28_731] and resolved.state == :created
    assert {:ok, _} = Machines.start(fixture.runtime, handle, resolved.version)
    wait_machine(fixture, handle, &(&1.state == :running))
  end

  test "background launch releases the command slot, persists launch evidence and retains reservations" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
    {:ok, command} = SmolBox.Command.new(["python", "-m", "http.server"], background: true)
    spec = %{fixture.spec | id: "server", command: command, outputs: []}

    assert {:error, %Error{category: :unsupported_capability}} =
             SmolBox.submit(fixture.runtime, spec)

    assert {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)

    assert {:ok,
            %{state: :launched, evidence: :launched, result: %SmolBox.LaunchResult{pid: 123}}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    machine = wait_machine(fixture, handle, &is_nil(&1.active_execution))
    assert machine.reserved_ports == [28_731] and machine.reservation.slots == 1
    assert {:ok, ^execution} = Machines.submit(fixture.runtime, handle, spec)

    assert {:error, %Error{category: :identity_conflict}} =
             Machines.submit(fixture.runtime, handle, %{
               spec
               | command: %{command | argv: ["other"]}
             })

    {:ok, stored} = SmolBox.fetch(fixture.runtime, elem(execution, 0), elem(execution, 1))
    assert {:ok, bytes} = Codec.encode(stored)
    assert <<"smolbox-record-v6\0", _::binary>> = bytes
    assert {:ok, ^stored} = Codec.decode(bytes)
    assert {:error, _} = Codec.encode(%{stored | state: :completed, evidence: :exited})

    assert {:error, _} =
             Codec.encode(%{
               stored
               | result: %SmolBox.Result{exit_code: 0, stdout: "", stderr: ""}
             })

    assert {:ok, _} = SmolBox.cancel(fixture.runtime, elem(execution, 0), elem(execution, 1))
    assert {:ok, next} = Machines.submit(fixture.runtime, handle, %{fixture.spec | id: "next"})
    assert {:ok, %{state: :completed}} = SmolBox.await(fixture.runtime, next, 5000)
    idle = wait_machine(fixture, handle, &is_nil(&1.active_execution))
    assert {:ok, _} = Machines.delete(fixture.runtime, handle, idle.version)
    deleted = wait_machine(fixture, handle, &(&1.state == :deleted))
    assert deleted.reservation == nil and deleted.reserved_ports == []
    assert {:ok, ^execution} = Machines.submit(fixture.runtime, handle, spec)
    assert [_, _] = ManagedPeer.snapshot(fixture.peer).commands
  end

  test "malformed background acknowledgment remains unknown and is never replayed" do
    fixture = RuntimeFixture.start(launch_stdout: "not-a-pid")
    handle = start_machine(fixture, [])
    {:ok, command} = SmolBox.Command.new(["server"], background: true)
    spec = %{fixture.spec | command: command, outputs: []}
    {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)

    assert {:ok, %{state: :unknown, result: nil}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    machine = wait_machine(fixture, handle, &(&1.state == :unknown))
    assert machine.active_execution == execution

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.submit(fixture.runtime, handle, %{spec | id: "second"})

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.stop(fixture.runtime, handle, machine.version)

    assert {:error, %Error{category: :admission_exhausted}} =
             Machines.delete(fixture.runtime, handle, machine.version)

    assert {:ok, ^execution} = Machines.submit(fixture.runtime, handle, spec)
    assert [_] = ManagedPeer.snapshot(fixture.peer).commands
  end

  for {event, phase, expected} <- [
        {:dispatch_intent, :after, :unknown},
        {:exec, :after, :unknown},
        {:result_write, :before, :unknown},
        {:result_write, :after, :launched}
      ] do
    @event event
    @phase phase
    @expected expected
    test "background recovery at #{@event}/#{@phase} preserves #{@expected} without replay" do
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: @event, phase: @phase, fired: false, observer: observer} end},
          id: :gate
        )

      fixture = RuntimeFixture.start(faults: gate)
      handle = start_machine(fixture, [%SmolBox.PortMapping{host: 28_731, guest: 8000}])
      {:ok, command} = SmolBox.Command.new(["server"], background: true)
      spec = %{fixture.spec | command: command, outputs: []}
      {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)
      event = @event
      phase = @phase
      assert_receive {:boundary, ^event, ^phase, blocked}, 5000
      stop_supervised!(SmolBox.Runtime)
      send(blocked, :release_boundary)
      runtime = start_supervised!({SmolBox.Runtime, fixture.options})
      fixture = %{fixture | runtime: runtime}
      expected = @expected
      assert {:ok, %{state: ^expected}} = SmolBox.await(runtime, execution, 5000)
      before = ManagedPeer.snapshot(fixture.peer).commands
      assert {:ok, ^execution} = Machines.submit(runtime, handle, spec)
      assert ManagedPeer.snapshot(fixture.peer).commands == before

      assert_background_recovery(fixture, handle, execution, expected)
    end
  end

  test "competing controllers cannot overlap launch or stop/delete while dispatch is pending" do
    observer = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: :exec, phase: :after, fired: false, observer: observer} end},
        id: :gate
      )

    fixture = RuntimeFixture.start(faults: gate)
    handle = start_machine(fixture, [])
    {:ok, command} = SmolBox.Command.new(["server"], background: true)
    spec = %{fixture.spec | command: command, outputs: []}

    other =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(fixture.options, :name, SmolBox.OtherBackgroundRuntime)},
        id: :other_runtime
      )

    {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)
    assert_receive {:boundary, :exec, :after, blocked}, 5000
    assert {:ok, ^execution} = Machines.submit(other, handle, spec)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.submit(other, handle, %{spec | id: "competing"})

    {:ok, busy} = Machines.inspect(other, handle)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.stop(other, handle, busy.version)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.delete(other, handle, busy.version)

    assert {:ok, _} = SmolBox.cancel(other, elem(execution, 0), elem(execution, 1))
    assert {:ok, %{state: :unknown}} = SmolBox.await(other, execution, 5000)
    send(blocked, :release_boundary)
    assert [_] = ManagedPeer.snapshot(fixture.peer).commands
  end

  test "a store without extended execution support rejects launch before staging or dispatch" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture, [])
    stop_supervised!(SmolBox.Runtime)

    runtime =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(fixture.options, :store, {LegacyStore, fixture.store})}
      )

    {:ok, command} = SmolBox.Command.new(["server"], background: true)
    spec = %{fixture.spec | command: command, outputs: []}
    assert {:error, %{category: :unsupported_capability}} = Machines.submit(runtime, handle, spec)
    assert ManagedPeer.snapshot(fixture.peer).commands == []
    stop_supervised!(Memory)
    assert {:error, %{category: :store}} = Machines.submit(runtime, handle, spec)
  end

  test "ownership mismatch prevents a background command from reaching the worker" do
    fixture = RuntimeFixture.start()
    handle = start_machine(fixture, [])
    {:ok, owned} = Machines.inspect(fixture.runtime, handle)

    Agent.update(fixture.peer, fn state ->
      update_in(state.machines[owned.machine_name]["createdAt"], &(&1 + 1))
    end)

    {:ok, command} = SmolBox.Command.new(["server"], background: true)
    spec = %{fixture.spec | command: command, outputs: []}
    assert {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)

    assert {:ok, %{state: :failed, evidence: :not_dispatched}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    assert ManagedPeer.snapshot(fixture.peer).commands == []
    wait_machine(fixture, handle, &(&1.state == :unknown))
  end

  test "cancellation before background dispatch prevents launch and releases a clean slot" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :dispatch_intent, phase: :before, fired: false, observer: observer} end},
        id: :gate
      )

    fixture = RuntimeFixture.start(faults: gate)
    handle = start_machine(fixture, [])
    {:ok, command} = SmolBox.Command.new(["server"], background: true)
    spec = %{fixture.spec | command: command, inputs: [], outputs: []}
    {:ok, execution} = Machines.submit(fixture.runtime, handle, spec)
    assert_receive {:boundary, :dispatch_intent, :before, blocked}, 5000
    assert {:ok, _} = SmolBox.cancel(fixture.runtime, elem(execution, 0), elem(execution, 1))
    send(blocked, :release_boundary)

    assert {:ok, %{state: :cancelled, evidence: :not_dispatched, result: nil}} =
             SmolBox.await(fixture.runtime, execution, 5000)

    wait_machine(fixture, handle, &is_nil(&1.active_execution))
    assert ManagedPeer.snapshot(fixture.peer).commands == []
  end

  test "an older observation cannot postpone or overwrite a newly accepted stop" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :inspect, phase: :after, fired: true, observer: observer}
         end},
        id: :stale_observation_gate
      )

    fixture = RuntimeFixture.start(faults: gate)
    handle = start_machine(fixture, [])
    coordinator = SmolBox.Runtime.coordinator(fixture.runtime)
    wait(fn -> {:ok, :sys.get_state(coordinator)} end, &(&1.active == %{}))
    Agent.update(gate, &%{&1 | fired: false})
    :ok = Machines.reconcile(fixture.runtime, handle)
    assert_receive {:boundary, :inspect, :after, blocked}, 5000
    {:ok, running} = Machines.inspect(fixture.runtime, handle)

    assert {:ok, %{state: :stopping, phase: :pending}} =
             Machines.stop(fixture.runtime, handle, running.version)

    send(blocked, :release_boundary)
    assert wait_machine(fixture, handle, &(&1.state == :stopped)).operation == nil
  end

  defp assert_background_recovery(fixture, handle, execution, :unknown) do
    machine = wait_machine(fixture, handle, &(&1.state == :unknown))
    assert machine.reserved_ports == [28_731] and machine.reservation.slots == 1
    assert {:error, _} = Machines.submit(fixture.runtime, handle, %{fixture.spec | id: "later"})

    Agent.update(fixture.peer, fn state ->
      put_in(state.machines[machine.machine_name]["state"], "stopped")
    end)

    {:ok, machine} = Machines.inspect(fixture.runtime, handle)

    assert {:ok, resolved} =
             Machines.resolve(fixture.runtime, handle, machine.version, quiesced: true)

    assert resolved.state == :stopped and resolved.active_execution == nil
    {:ok, unknown} = SmolBox.fetch(fixture.runtime, elem(execution, 0), elem(execution, 1))

    assert unknown.state == :unknown and unknown.result == nil and
             unknown.cleanup == :complete
  end

  defp assert_background_recovery(fixture, handle, execution, :launched) do
    wait_machine(fixture, handle, &is_nil(&1.active_execution))
    {:ok, launch} = SmolBox.fetch(fixture.runtime, elem(execution, 0), elem(execution, 1))
    assert launch.result.pid == 123
  end

  defp start_machine(fixture, mappings) do
    handle = create(fixture, mappings)
    created = wait_machine(fixture, handle, &(&1.state == :created))
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    wait_machine(fixture, handle, &(&1.state == :running))
    handle
  end

  defp create(fixture, mappings) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "computer",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile,
        ports: mappings
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
