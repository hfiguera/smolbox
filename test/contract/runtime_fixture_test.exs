defmodule SmolBox.RuntimeFixtureTest do
  use ExUnit.Case, async: true
  alias SmolBox.RuntimeFixture

  test "fixture waits for readiness after a failed initial health probe" do
    observer =
      Task.async(fn ->
        assert_receive {:boundary, :http_read, :before, blocked}, 2000
        wait_failed_probe(System.monotonic_time(:millisecond) + 2000)
        send(blocked, :release_boundary)
        :released
      end)

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :http_read, phase: :before, observer: observer.pid, fired: false} end},
        id: :startup_probe
      )

    fixture = RuntimeFixture.start(__MODULE__, faults: gate)
    assert Task.await(observer) == :released
    assert {:ok, [%{status: :ready}]} = SmolBox.workers(fixture.runtime)
    assert {:ok, handle} = SmolBox.submit(fixture.runtime, fixture.spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(fixture.runtime, handle, 5000)
  end

  defp wait_failed_probe(deadline) do
    {:ok, [worker]} = SmolBox.workers(__MODULE__)

    if worker.status == :unavailable and worker.health_checked_at_ms != nil do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "initial health probe did not report its timeout"

      Process.sleep(10)
      wait_failed_probe(deadline)
    end
  end
end
