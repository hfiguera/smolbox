defmodule SmolBox.RuntimeFixtureTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Runtime, RuntimeFixture}

  test "idle wait includes pending claims on every controller sharing the store" do
    gate = start_supervised!({Agent, fn -> %{} end}, id: :gate)
    f = RuntimeFixture.start(__MODULE__, faults: gate)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "idle-wait",
        artifact: f.spec.artifact,
        profile: f.spec.profile
      )

    {:ok, handle} = Machines.create(f.runtime, spec)
    # Establish the idle-machine precondition before another controller can claim
    # its queued creation without owning the worker lease. This test exercises
    # pending reconciliation claims, not competing admission during startup.
    assert %{state: :created} = RuntimeFixture.await_idle(f.runtime, handle)

    second =
      start_supervised!({Runtime, Keyword.put(f.options, :name, SmolBox.IdleSecond)},
        id: :second
      )

    idle = RuntimeFixture.await_idle([second, f.runtime], handle)
    observer = self()

    Agent.update(gate, fn _ ->
      %{event: :machine_claim, phase: :before, fired: false, observer: observer}
    end)

    assert :ok = Machines.reconcile(f.runtime, handle)
    assert_receive {:boundary, :machine_claim, :before, blocked}, 5000
    # The public await sees an idle record even though this claim will change its version.
    assert {:ok, %{version: version}} = Machines.await(second, handle, 1000)
    assert version == idle.version

    assert_raise ExUnit.AssertionError, ~r/machine did not become quiescent/, fn ->
      RuntimeFixture.await_idle([second, f.runtime], handle, System.monotonic_time(:millisecond))
    end

    send(blocked, :release_boundary)
    fresh = RuntimeFixture.await_idle([second, f.runtime], handle)
    assert fresh.version > idle.version
    assert {:ok, _} = Machines.delete(f.runtime, handle, fresh.version)
    assert {:ok, %{state: :deleted}} = Machines.await(f.runtime, handle, 5000)
  end

  test "fixture waits for readiness after consecutive failed health probes" do
    # Two cached failures require a third probe, more than ten seconds after
    # startup. Inject the failures instead of relying on CI scheduling delays.
    fixture = RuntimeFixture.start(__MODULE__, health_failures: 2)
    peer = ManagedPeer.snapshot(fixture.peer)
    assert peer.options[:health_failures] == 0
    assert Enum.count(peer.operations, &(&1 == {"GET", "/health"})) >= 3
    assert {:ok, [%{status: :ready}]} = SmolBox.workers(fixture.runtime)
    assert {:ok, handle} = SmolBox.submit(fixture.runtime, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(fixture.runtime, handle, 5000)
  end
end
