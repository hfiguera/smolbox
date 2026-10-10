defmodule SmolBox.ReconciliationCapacityTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Runtime, RuntimeFixture}
  alias SmolBox.Runtime.Executor

  test "queued cancellation and expiry progress while execution capacity is occupied" do
    f = RuntimeFixture.start(__MODULE__, hold: true, max_active: 1)
    {:ok, busy} = SmolBox.submit(f.runtime, f.spec)
    wait(fn -> fetch(f, busy) end, &(&1.state == :running))

    {:ok, cancelled} = SmolBox.submit(f.runtime, %{f.spec | id: "cancelled"})
    {:ok, _} = SmolBox.cancel(f.runtime, elem(cancelled, 0), elem(cancelled, 1))

    assert %{state: :cancelled, cleanup: :complete, machine_name: nil} =
             wait(fn -> fetch(f, cancelled) end, &(&1.state == :cancelled))

    {:ok, expired} = SmolBox.submit(f.runtime, %{f.spec | id: "expired", queue_ms: 50})

    assert %{state: :expired, cleanup: :complete, machine_name: nil} =
             wait(fn -> fetch(f, expired) end, &(&1.state == :expired))

    assert fetch(f, busy).state == :running
    assert [_] = ManagedPeer.snapshot(f.peer).commands
    assert :ok = SmolBox.reconcile(f.runtime, elem(busy, 0), elem(busy, 1))
    cancel_running(f, busy)
  end

  test "an unrelated machine lifecycle progresses while execution capacity is occupied" do
    f = RuntimeFixture.start(__MODULE__, hold: true, max_active: 1, slots: 3)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "maintained",
        artifact: f.spec.artifact,
        profile: f.spec.profile
      )

    {:ok, machine} = Machines.create(f.runtime, spec)
    current = RuntimeFixture.await_idle(f.runtime, machine)
    {:ok, busy} = SmolBox.submit(f.runtime, f.spec)
    wait(fn -> fetch(f, busy) end, &(&1.state == :running))
    assert {:ok, _} = Machines.delete(f.runtime, machine, current.version)
    assert {:ok, %{state: :deleted, reservation: nil}} = Machines.await(f.runtime, machine, 1000)
    assert fetch(f, busy).state == :running
    cancel_running(f, busy)
  end

  test "the maintenance lane stays bounded and cannot admit extra executions" do
    gate = start_supervised!({Agent, fn -> %{} end}, id: :gate)
    f = RuntimeFixture.start(__MODULE__, hold: true, max_active: 1, slots: 3, faults: gate)
    {:ok, busy} = SmolBox.submit(f.runtime, f.spec)
    wait(fn -> fetch(f, busy) end, &(&1.state == :running))

    coordinator = Runtime.coordinator(f.runtime)
    observer = self()

    Agent.update(gate, fn _ ->
      %{event: :absence_record, phase: :before, observer: observer, fired: false}
    end)

    {:ok, cancelled} = SmolBox.submit(f.runtime, %{f.spec | id: "held-cancellation"})
    {:ok, _} = SmolBox.cancel(f.runtime, elem(cancelled, 0), elem(cancelled, 1))
    assert_receive {:boundary, :absence_record, :before, blocked}, 3000
    {:ok, extra} = SmolBox.submit(f.runtime, %{f.spec | id: "extra"})

    assert {:error, %{category: :admission_exhausted}} =
             SmolBox.reconcile(f.runtime, elem(extra, 0), elem(extra, 1))

    state = :sys.get_state(coordinator)
    assert map_size(state.active) == 2
    assert MapSet.size(state.maintenance) == 1
    assert Enum.count_until(Task.Supervisor.children(state.tasks), 4) <= 3
    assert fetch(f, extra).state == :accepted
    {:ok, config} = GenServer.call(coordinator, :config)
    assert false == Executor.run(config, extra, ["peer"], :maintenance)
    assert [_] = ManagedPeer.snapshot(f.peer).commands
    send(blocked, :release_boundary)
    SmolBox.cancel(f.runtime, elem(extra, 0), elem(extra, 1))
    cancel_running(f, busy)
  end

  test "interrupted cleanup progresses while a different execution occupies the normal slot" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :absence_record, phase: :before, observer: observer, fired: false}
         end},
        id: :gate
      )

    f = RuntimeFixture.start(__MODULE__, max_active: 1, slots: 2, faults: gate)
    {:ok, finished} = SmolBox.submit(f.runtime, f.spec)
    assert_receive {:boundary, :absence_record, :before, interrupted}, 3000
    original = fetch(f, finished)
    assert original.state == :completed and original.cleanup != :complete

    # Stop after verified deletion but before its absence is persisted. Hold the
    # replacement cleanup attempt while a second command starts independently.
    Agent.update(gate, &%{&1 | fired: false})
    %{tasks: tasks} = :sys.get_state(Runtime.coordinator(f.runtime))
    assert :ok = Task.Supervisor.terminate_child(tasks, interrupted)
    assert_receive {:boundary, :absence_record, :before, cleanup}, 3000
    Agent.update(f.peer, &%{&1 | options: Keyword.put(&1.options, :hold, true)})
    {:ok, busy} = SmolBox.submit(f.runtime, %{f.spec | id: "busy-during-cleanup"})
    wait(fn -> fetch(f, busy) end, &(&1.state == :running))
    send(cleanup, :release_boundary)

    clean =
      wait(fn -> fetch(f, finished) end, &(&1.cleanup == :complete and &1.reservation == nil))

    assert clean.reservation == nil and clean.result == original.result
    assert fetch(f, busy).state == :running
    assert [_, _] = ManagedPeer.snapshot(f.peer).commands
    cancel_running(f, busy)
  end

  defp cancel_running(f, {scope, id} = handle) do
    assert {:ok, ^handle} = SmolBox.cancel(f.runtime, scope, id)
    wait(fn -> fetch(f, handle) end, &(&1.evidence == :termination_confirmed))
  end

  defp fetch(f, {scope, id}) do
    {:ok, record} = SmolBox.fetch(f.runtime, scope, id)
    record
  end

  defp wait(fetch, predicate, deadline \\ System.monotonic_time(:millisecond) + 1000) do
    record = fetch.()

    if predicate.(record) do
      record
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "reconciliation did not progress: #{inspect(record)}"

      Process.sleep(10)
      wait(fetch, predicate, deadline)
    end
  end
end
