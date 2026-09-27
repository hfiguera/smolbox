defmodule SmolBox.RuntimeFixtureTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedPeer, RuntimeFixture}

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
