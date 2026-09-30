defmodule SmolBox.WorkerReportsTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Profile, RuntimeFixture}
  alias SmolBox.Store.Memory

  @capacity %{
    "allocated_cpus" => 0,
    "allocated_memory_mb" => 0,
    "used_cpus" => 0.0,
    "used_memory_mb" => 0,
    "used_disk_gb" => 0
  }

  test "reports separate live utilization from reservations and explain retained capacity" do
    fixture = RuntimeFixture.start(__MODULE__, observed_capacity: @capacity)
    assert {:ok, [eligible]} = SmolBox.admission_report(fixture.runtime, fixture.spec)
    assert eligible.blockers == []
    assert eligible.required.memory_mb == 512
    assert {:ok, created_spec} = managed_spec(fixture)
    assert {:ok, handle} = Machines.create(fixture.runtime, created_spec)
    owned = RuntimeFixture.await_idle(fixture.runtime, handle)
    assert owned.state == :created

    assert {:ok, report} = SmolBox.worker_report(fixture.runtime, "peer")
    assert report.reserved == Profile.resources(created_spec.profile)
    assert report.remaining == %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}
    assert report.observed_capacity.used_disk_gb == 0
    assert report.capacity_error == nil and report.usage_error == nil
    assert {:ok, [blocked]} = SmolBox.admission_report(fixture.runtime, created_spec)
    assert blocked.blockers == Enum.map([:slots, :cpus, :memory_mb, :disk_gb], &{:capacity, &1})
    assert {:ok, ^owned} = Machines.inspect(fixture.runtime, handle)
    assert {:ok, used} = Memory.usage(fixture.store, "peer")
    assert used == report.reserved
  end

  test "live endpoint failure leaves store headroom intact and diagnostics do not call admission mutations" do
    fixture = RuntimeFixture.start(__MODULE__)
    assert {:ok, report} = SmolBox.worker_report(fixture.runtime, "peer")
    assert report.observed_capacity == nil
    assert report.capacity_error.operation == :capacity
    assert report.reserved == %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}
    assert {:ok, [eligible]} = SmolBox.admission_report(fixture.runtime, fixture.spec)
    assert eligible.blockers == []
    assert :ok = SmolBox.drain_worker(fixture.runtime, "peer")
    assert {:ok, [drained]} = SmolBox.admission_report(fixture.runtime, fixture.spec)
    assert drained.blockers == [:draining]
    assert {:ok, _} = SmolBox.worker_report(fixture.runtime, "peer")

    assert Enum.all?(ManagedPeer.snapshot(fixture.peer).operations, fn {method, _} ->
             method == "GET"
           end)

    assert {:error, %{category: :not_found}} = SmolBox.worker_report(fixture.runtime, "missing")
  end

  test "store failure is unknown accounting even when worker telemetry is healthy" do
    observer = self()
    faults = start_supervised!({Agent, fn -> %{observer: observer} end}, id: :faults)
    fixture = RuntimeFixture.start(__MODULE__, observed_capacity: @capacity, faults: faults)
    Agent.update(faults, &Map.put(&1, :failure, {:usage, :before}))
    assert {:ok, report} = SmolBox.worker_report(fixture.runtime, "peer")
    assert report.reserved == nil and report.remaining == nil
    assert report.usage_error.category == :store
    assert report.observed_capacity.used_cpus == 0
    Agent.update(faults, &Map.put(&1, :failure, {:usage, :before}))
    assert {:ok, [blocked]} = SmolBox.admission_report(fixture.runtime, fixture.spec)
    assert blocked.blockers == [:store_unavailable]
    assert blocked.remaining == nil
  end

  test "unsupported profiles and invalid specifications cannot look eligible" do
    fixture = RuntimeFixture.start(__MODULE__)
    different = %{fixture.spec | profile: %{fixture.spec.profile | id: "unapproved"}}
    assert {:ok, [blocked]} = SmolBox.admission_report(fixture.runtime, different)
    assert blocked.blockers == [:unsupported_spec]
    assert {:error, %{category: :validation}} = SmolBox.admission_report(fixture.runtime, %{})

    assert {:error, %{category: :validation}} =
             SmolBox.admission_report(fixture.runtime, %{different | profile: nil})
  end

  test "managed measurement changes never change identity, reservations or durable history" do
    fixture = RuntimeFixture.start(__MODULE__)
    {:ok, spec} = managed_spec(fixture)
    {:ok, handle} = Machines.create(fixture.runtime, spec)
    owned = RuntimeFixture.await_idle(fixture.runtime, handle)
    {:ok, usage} = Memory.usage(fixture.store, "peer")

    Agent.update(fixture.peer, fn state ->
      update_in(
        state.machines[owned.machine_name],
        &Map.merge(&1, %{"cpuMillis" => 123, "rssMb" => 42})
      )
    end)

    assert {:ok, %{cpu_millis: 123, rss_mb: 42}} = Machines.measurements(fixture.runtime, handle)
    assert {:ok, ^owned} = Machines.inspect(fixture.runtime, handle)
    assert {:ok, ^usage} = Memory.usage(fixture.store, "peer")

    Agent.update(fixture.peer, fn state ->
      update_in(state.machines[owned.machine_name]["createdAt"], &(&1 + 1))
    end)

    assert {:error, %{category: :identity_conflict}} =
             Machines.measurements(fixture.runtime, handle)

    assert {:ok, ^usage} = Memory.usage(fixture.store, "peer")
    Agent.update(fixture.peer, &%{&1 | machines: %{}})
    assert {:error, %{category: :not_found}} = Machines.measurements(fixture.runtime, handle)
    assert {:ok, ^usage} = Memory.usage(fixture.store, "peer")
  end

  test "a stalled capacity probe is bounded outside the coordinator" do
    observer = self()
    faults = start_supervised!({Agent, fn -> %{observer: observer} end}, id: :faults)
    fixture = RuntimeFixture.start(__MODULE__, faults: faults)
    Agent.update(faults, &Map.merge(&1, %{event: :capacity, phase: :before, fired: false}))
    task = Task.async(fn -> SmolBox.worker_report(fixture.runtime, "peer") end)
    assert_receive {:boundary, :capacity, :before, handler}, 2000
    assert {:ok, [%{id: "peer"}]} = SmolBox.workers(fixture.runtime)
    assert :ok = SmolBox.drain_worker(fixture.runtime, "peer")
    assert {:ok, report} = Task.await(task, 3000)
    assert report.capacity_error.category == :transport
    assert report.observed_capacity == nil
    assert report.reserved.slots == 0
    send(handler, :release_boundary)
  end

  test "the report enforces its own small response budget" do
    large = Map.put(@capacity, "additive_field", String.duplicate("x", 8192))
    fixture = RuntimeFixture.start(__MODULE__, observed_capacity: large)
    assert {:ok, report} = SmolBox.worker_report(fixture.runtime, "peer")
    assert report.capacity_error.category == :output_limit
    assert report.observed_capacity == nil and report.reserved.slots == 0
  end

  defp managed_spec(fixture) do
    ManagedMachineSpec.new(
      scope: fixture.spec.scope,
      id: "observed",
      artifact: fixture.spec.artifact,
      profile: fixture.spec.profile
    )
  end
end
