defmodule SmolBox.WorkerPoolTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Client, Error, ManagedPeer, Runtime, RuntimeFixture, TestPeer, Worker}
  alias SmolBox.Runtime.{Clock, WorkerHealth}

  for {options, status} <- [
        {[runtime_version: "1.15.0"], :incompatible},
        {[unready: true], :degraded},
        {[inventory_unavailable: true], :degraded}
      ] do
    test "#{inspect(options)} prevents admission while allowing read-only inspection" do
      context = RuntimeFixture.start(unquote(options))
      status = unquote(status)
      wait_status(context.runtime, status)
      spec = %{context.spec | queue_ms: 50}
      assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
      assert {:ok, expired} = SmolBox.await(context.runtime, handle, 5000)
      assert expired.state == :expired and expired.reservation == nil
      assert expired.machine_name == nil
      assert {:ok, %{candidates: []}} = SmolBox.audit_worker(context.runtime, "peer")
      assert ManagedPeer.snapshot(context.peer).commands == []

      assert Enum.all?(ManagedPeer.snapshot(context.peer).operations, fn {method, _path} ->
               method == "GET"
             end)
    end
  end

  test "a healthy second worker receives work while a degraded first worker stays inspectable" do
    context = RuntimeFixture.start(unready: true)
    stop_supervised!(Runtime)
    {second, port} = ManagedPeer.start()

    {:ok, endpoint} =
      Worker.new("second", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)
    [first] = context.options[:workers]
    options = Keyword.put(context.options, :workers, [first, %{first | client: client}])
    runtime = start_supervised!({Runtime, options})
    assert {:ok, handle} = SmolBox.submit(runtime, context.spec)
    assert {:ok, record} = SmolBox.await(runtime, handle, 5000)
    assert record.state == :completed and record.worker_id == "second"
    assert ManagedPeer.snapshot(context.peer).commands == []
    assert match?([_command], ManagedPeer.snapshot(second).commands)
    assert {:ok, reports} = SmolBox.workers(runtime)
    assert [first_report, %{status: :ready, health: %{version: "1.14.1"}}] = reports
    assert first_report.status in [:degraded, :unavailable]
    assert {:ok, %{candidates: []}} = SmolBox.audit_worker(runtime, "peer")
    assert wait_cleanup(runtime, handle).reservation == nil
  end

  test "fresh admission checks reject a version changed after the cached readiness observation" do
    context = RuntimeFixture.start()
    wait_status(context.runtime, :ready)

    Agent.update(context.peer, fn state ->
      %{state | options: Keyword.put(state.options, :runtime_version, "1.15.0")}
    end)

    assert {:ok, handle} = SmolBox.submit(context.runtime, %{context.spec | queue_ms: 100})
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :expired and record.reservation == nil
    assert ManagedPeer.snapshot(context.peer).machines == %{}
    assert ManagedPeer.snapshot(context.peer).commands == []
  end

  test "stale observations never authorize admission and unavailable probes are bounded" do
    context = RuntimeFixture.start()
    [worker] = context.options[:workers]
    report = WorkerHealth.observe(worker, Clock)
    assert WorkerHealth.status(report, report.checked_monotonic) == :ready
    assert WorkerHealth.status(report, report.checked_monotonic + 5001) == :unavailable
    assert WorkerHealth.status(report, report.checked_monotonic - 1) == :unavailable
    assert WorkerHealth.status(nil, 0) == :unavailable

    port =
      TestPeer.start(fn conn ->
        receive do
        after
          1500 -> TestPeer.json(conn, %{})
        end
      end)

    {:ok, endpoint} =
      Worker.new("missing", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)
    started = System.monotonic_time(:millisecond)

    assert %{status: :unavailable, health: nil} =
             WorkerHealth.observe(%{worker | client: client}, Clock)

    assert System.monotonic_time(:millisecond) - started < 1200

    assert {:error, %Error{category: :not_found}} =
             SmolBox.drain_worker(context.runtime, "missing")
  end

  test "version drift during preparation prevents dispatch and still cleans the original VM" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :creation_record, phase: :after, observer: observer, fired: false} end},
        id: :prepared_gate
      )

    context = RuntimeFixture.start(faults: gate)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert_receive {:boundary, :creation_record, :after, blocked}, 5000

    Agent.update(context.peer, fn state ->
      %{state | options: Keyword.put(state.options, :runtime_version, "1.15.0")}
    end)

    send(blocked, :release_boundary)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :failed and record.evidence == :not_dispatched
    assert record.last_error.category == :unsupported_capability
    assert ManagedPeer.snapshot(context.peer).commands == []
    assert :ok = SmolBox.reconcile(context.runtime, context.spec.scope, context.spec.id)
    assert wait_cleanup(context.runtime, handle).reservation == nil
    assert ManagedPeer.snapshot(context.peer).machines == %{}
  end

  defp wait_cleanup(runtime, handle, remaining \\ 100)
  defp wait_cleanup(_runtime, _handle, 0), do: flunk("owned cleanup did not complete")

  defp wait_cleanup(runtime, {scope, id} = handle, remaining) do
    case SmolBox.fetch(runtime, scope, id) do
      {:ok, %{cleanup: :complete, reservation: nil} = record} ->
        record

      _pending ->
        receive do
        after
          20 -> wait_cleanup(runtime, handle, remaining - 1)
        end
    end
  end

  defp wait_status(runtime, expected, remaining \\ 100)
  defp wait_status(_runtime, _expected, 0), do: flunk("worker health observation did not arrive")

  defp wait_status(runtime, expected, remaining) do
    case SmolBox.workers(runtime) do
      {:ok, [%{status: ^expected}]} ->
        :ok

      _pending ->
        receive do
        after
          20 -> wait_status(runtime, expected, remaining - 1)
        end
    end
  end
end
