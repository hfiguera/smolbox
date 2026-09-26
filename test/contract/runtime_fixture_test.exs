defmodule SmolBox.RuntimeFixtureTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedPeer, RuntimeFixture}

  test "fixture waits for readiness after a failed initial health probe" do
    # Fail the first probe explicitly instead of racing fixture startup against
    # an observer timeout. The runtime must refresh its cached failed health.
    fixture = RuntimeFixture.start(__MODULE__, health_failures: 1)
    peer = ManagedPeer.snapshot(fixture.peer)
    assert peer.options[:health_failures] == 0
    assert Enum.count(peer.operations, &(&1 == {"GET", "/health"})) >= 2
    assert {:ok, [%{status: :ready}]} = SmolBox.workers(fixture.runtime)
    assert {:ok, handle} = SmolBox.submit(fixture.runtime, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(fixture.runtime, handle, 5000)
  end
end
