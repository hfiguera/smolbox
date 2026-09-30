defmodule SmolBox.WorkerDrainingTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Runtime, RuntimeFixture}
  alias SmolBox.Store.Memory

  test "drain survives controller restart, is shared, and existing machine cleanup continues" do
    f = RuntimeFixture.start(__MODULE__)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "retained",
        profile: f.spec.profile,
        artifact: f.spec.artifact
      )

    {:ok, handle} = Machines.create(f.runtime, spec)
    RuntimeFixture.await_idle(f.runtime, handle)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")

    second =
      start_supervised!({Runtime, Keyword.put(f.options, :name, SmolBox.DrainSecond)},
        id: :second
      )

    assert {:ok, [%{status: :draining, admission_control: %{version: 1}}]} =
             SmolBox.workers(second)

    assert {:ok, %{records: [%{id: "retained"}], assessment: :blocked}} =
             SmolBox.worker_maintenance(second, "peer")

    stop_supervised!(Runtime)
    restarted = start_supervised!({Runtime, f.options})
    assert {:ok, [%{status: :draining}]} = SmolBox.workers(restarted)

    assert {:ok, queued} =
             SmolBox.submit(restarted, %{f.spec | id: "cannot-assign", queue_ms: 100})

    assert {:ok, %{state: :expired, worker_id: nil}} = SmolBox.await(restarted, queued, 5000)
    assert [_original] = ManagedPeer.snapshot(f.peer).creations

    # Draining does not prohibit starting an existing assignment or running a command.
    recovered = RuntimeFixture.await_idle([restarted, second], handle)
    assert {:ok, _} = Machines.start(restarted, handle, recovered.version)
    assert {:ok, %{state: :running}} = Machines.await(restarted, handle, 10_000)
    assert {:ok, command} = Machines.submit(restarted, handle, %{f.spec | id: "existing-command"})
    assert {:ok, %{state: :completed}} = SmolBox.await(restarted, command, 10_000)
    idle = RuntimeFixture.await_idle([restarted, second], handle)
    assert {:ok, _} = Machines.delete(restarted, handle, idle.version)
    assert {:ok, %{state: :deleted}} = Machines.await(restarted, handle, 10_000)
    assert {:ok, report} = SmolBox.worker_maintenance(restarted, "peer")
    assert report.records == [] and report.assessment == :operator_quiescence_required
    assert report.reserved == %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}

    assert {:ok, %{mode: :active}} =
             SmolBox.resume_worker(restarted, "peer", report.control.version)

    assert {:ok, %{control: %{mode: :active}}} = SmolBox.worker_maintenance(second, "peer")

    refute Enum.any?(ManagedPeer.snapshot(f.peer).operations, fn {_, path} -> path == "/drain" end)
  end

  test "a new versioned drain invalidates an outstanding resume even while already draining" do
    f = RuntimeFixture.start(__MODULE__)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")
    assert {:ok, second} = SmolBox.drain_worker(f.runtime, "peer", 1)
    assert second.version == 2
    assert {:ok, ^second} = SmolBox.drain_worker(f.runtime, "peer", 1)
    assert {:error, %{category: :stale_version}} = SmolBox.resume_worker(f.runtime, "peer", 1)
    assert {:ok, active} = SmolBox.resume_worker(f.runtime, "peer", 2)
    assert {:ok, ^active} = SmolBox.resume_worker(f.runtime, "peer", 2)
  end

  test "store failure is not active admission or shutdown clearance" do
    f = RuntimeFixture.start(__MODULE__)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")
    stop_supervised!(Memory)
    assert {:error, %{category: :store}} = SmolBox.drain_worker(f.runtime, "peer")
    assert {:error, %{category: :store}} = SmolBox.worker_maintenance(f.runtime, "peer")
    assert {:error, %{category: :store}} = SmolBox.resume_worker(f.runtime, "peer", 1)

    assert {:ok, [%{status: :unavailable, admission_error: %{category: :store}}]} =
             SmolBox.workers(f.runtime)

    assert ManagedPeer.snapshot(f.peer).creations == []
  end

  test "uncertain creation remains a maintenance blocker with its reservations intact" do
    f = RuntimeFixture.start(__MODULE__, create_lost: true)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "uncertain",
        profile: f.spec.profile,
        artifact: f.spec.artifact
      )

    {:ok, handle} = Machines.create(f.runtime, spec)
    assert {:ok, %{state: :unknown}} = Machines.await(f.runtime, handle, 5000)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")
    assert {:ok, report} = SmolBox.worker_maintenance(f.runtime, "peer")
    assert report.assessment == :blocked and report.reserved.slots == 1
    assert [%{id: "uncertain", state: :unknown, operation: :create}] = report.records
  end

  test "static admission restrictions cannot be overridden by resume" do
    f = RuntimeFixture.start(__MODULE__, draining: true, wait_ready: false)
    assert :ok = SmolBox.drain_worker(f.runtime, "peer")

    assert {:error, %{category: :unsupported_capability}} =
             SmolBox.resume_worker(f.runtime, "peer", 1)

    assert {:error, %{category: :validation}} =
             SmolBox.worker_maintenance(f.runtime, "peer", limit: 101)

    assert {:error, %{category: :not_found}} = SmolBox.drain_worker(f.runtime, "missing")
  end
end
