defmodule SmolBox.RuntimeFaultTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Files, ManagedPeer, Runtime, RuntimeFixture}

  @boundaries [
    {:accept, :before},
    {:accept, :after},
    {:reserve, :before},
    {:reserve, :after},
    {:create, :before},
    {:create, :after},
    {:creation_record, :before},
    {:creation_record, :after},
    {:upload, :before},
    {:upload, :after},
    {:dispatch_intent, :before},
    {:dispatch_intent, :after},
    {:exec, :before},
    {:exec, :after},
    {:first_output, :after},
    {:first_output_record, :before},
    {:first_output_record, :after},
    {:exit, :before},
    {:exit, :after},
    {:result_write, :before},
    {:result_write, :after},
    {:artifact_put, :before},
    {:artifact_put, :after},
    {:artifact_record, :before},
    {:artifact_record, :after},
    {:completion_record, :before},
    {:completion_record, :after},
    {:stop, :before},
    {:stop, :after},
    {:delete, :before},
    {:delete, :after},
    {:absence_record, :before},
    {:absence_record, :after},
    {:release, :before},
    {:release, :after}
  ]

  for {event, phase} <- @boundaries do
    @tag boundary: {event, phase}
    test "controller interruption at #{event}/#{phase} preserves identity, command count and capacity",
         %{boundary: boundary} do
      exercise(boundary)
    end
  end

  test "a delayed create response cannot turn temporary absence into released capacity" do
    {context, spec, blocked, submission} = blocked_request(:create)
    stop_supervised!(Runtime)
    Task.shutdown(submission, :brutal_kill)
    runtime = start_supervised!({Runtime, context.options})
    retained = settled(runtime)
    assert retained.cleanup == :failed
    assert retained.created_machine == nil
    assert retained.reservation != nil
    assert ManagedPeer.snapshot(context.peer).machines == %{}
    send(blocked, :release_boundary)
    wait_peer(context.peer, fn state -> Map.has_key?(state.machines, retained.machine_name) end)
    assert :ok = SmolBox.reconcile(runtime, spec.scope, spec.id)
    {:ok, still_retained} = SmolBox.fetch(runtime, spec.scope, spec.id)
    assert still_retained.reservation != nil
    assert ManagedPeer.snapshot(context.peer).commands == []
  end

  test "a previously sent exec arriving after stop is observed and stopped again without replay" do
    {context, spec, blocked, submission} = blocked_request(:exec)
    stop_supervised!(Runtime)
    Task.shutdown(submission, :brutal_kill)
    runtime = start_supervised!({Runtime, context.options})
    stopped = settled(runtime)
    assert stopped.evidence == :termination_confirmed
    assert ManagedPeer.snapshot(context.peer).commands == []
    send(blocked, :release_boundary)
    wait_peer(context.peer, fn state -> match?([_command], state.commands) end)

    wait_peer(context.peer, fn state ->
      state.machines[stopped.machine_name]["state"] == "stopped" and
        Enum.count(state.operations, fn {_method, path} -> String.ends_with?(path, "/stop") end) >=
          2
    end)

    {:ok, record} = SmolBox.fetch(runtime, spec.scope, spec.id)
    assert record.state == :unknown
    assert record.reservation != nil
    assert record.result == nil
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
  end

  defp blocked_request(event) do
    parent = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: event, phase: :before, observer: parent, fired: false} end},
        id: :late_gate
      )

    context = RuntimeFixture.start(faults: gate)
    submission = Task.async(fn -> SmolBox.submit(context.runtime, context.spec) end)
    Process.unlink(submission.pid)
    assert_receive {:boundary, ^event, :before, blocked}, 6000
    {context, context.spec, blocked, submission}
  end

  defp wait_peer(peer, predicate, attempts \\ 200)
  defp wait_peer(_peer, _predicate, 0), do: flunk("worker did not reach the expected state")

  defp wait_peer(peer, predicate, attempts) do
    if predicate.(ManagedPeer.snapshot(peer)) do
      :ok
    else
      receive do
      after
        25 -> wait_peer(peer, predicate, attempts - 1)
      end
    end
  end

  defp exercise({event, phase}) do
    parent = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: event, phase: phase, observer: parent, fired: false} end},
        id: :gate
      )

    context = RuntimeFixture.start(faults: gate, hold: event == :first_output_record)

    spec = %{
      context.spec
      | inputs: [
          %{
            "source" => "input",
            "path" => "/workspace/in",
            "size" => 2,
            "sha256" => Files.sha256(<<0, 255>>),
            "mode" => "runtime_default"
          }
        ],
        outputs: [%{"destination" => "output", "path" => "/workspace/out.bin", "max_bytes" => 32}]
    }

    submission = Task.async(fn -> SmolBox.submit(context.runtime, spec) end)
    Process.unlink(submission.pid)
    assert_receive {:boundary, ^event, ^phase, blocked}, 6000
    stop_supervised!(Runtime)
    Task.shutdown(submission, :brutal_kill)
    send(blocked, :release_boundary)
    runtime = start_supervised!({Runtime, context.options})
    assert {:ok, {"contract", "one"}} = SmolBox.submit(runtime, spec)
    record = settled(runtime)
    assert record.scope == spec.scope and record.id == spec.id
    assert Enum.count_until(ManagedPeer.snapshot(context.peer).commands, 2) <= 1
    assert record.state in [:completed, :failed, :unknown]
    assert_accounting(record, context.peer)
    assert {:ok, {"contract", "one"}} = SmolBox.submit(runtime, spec)
    refute record.evidence == :exited and record.result == nil
  end

  defp assert_accounting(%{cleanup: :complete} = record, peer) do
    assert record.reservation == nil
    assert record.absence_at_ms != nil
    refute Map.has_key?(ManagedPeer.snapshot(peer).machines, record.machine_name)
  end

  defp assert_accounting(record, _peer) do
    assert record.reservation != nil

    if record.state == :unknown do
      assert record.result == nil
      assert record.evidence == :termination_confirmed
    else
      assert record.created_machine == nil
      assert record.cleanup == :failed
      assert record.evidence == :not_dispatched
    end
  end

  defp settled(runtime, attempts \\ 250)
  defp settled(_runtime, 0), do: flunk("recovery did not settle")

  defp settled(runtime, attempts) do
    {:ok, record} = SmolBox.fetch(runtime, "contract", "one")
    complete = record.cleanup == :complete and record.reservation == nil
    retained = record.state == :unknown and record.evidence == :termination_confirmed

    if complete or retained or record.cleanup == :failed,
      do: record,
      else: pause(runtime, attempts)
  end

  defp pause(runtime, attempts) do
    receive do
    after
      25 -> settled(runtime, attempts - 1)
    end
  end
end
