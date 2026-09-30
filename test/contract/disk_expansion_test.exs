defmodule SmolBox.DiskExpansionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machines, ManagedMachineSpec, ManagedPeer, Runtime, RuntimeFixture}
  alias SmolBox.Store.{Contract, Memory}

  defp machine(f, options \\ []) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        [scope: f.spec.scope, id: "growable", artifact: f.spec.artifact, profile: f.spec.profile] ++
          options
      )

    {:ok, handle} = Machines.create(f.runtime, spec)
    {handle, RuntimeFixture.await_idle(f.runtime, handle)}
  end

  test "growth survives restart; start, commands, measurements, stop and delete use new allocations" do
    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10))
    {handle, created} = machine(f)

    assert {:ok, _} =
             Machines.expand_disks(f.runtime, handle, "bigger", created.version,
               storage_gb: 3,
               overlay_gb: 2
             )

    {:ok, grown} = Machines.await(f.runtime, handle, 10_000)
    assert grown.disk_expansions["bigger"].state == :completed
    assert grown.created_machine == created.created_machine
    assert grown.observed_machine.storage_gb == 3
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 30_000)
    assert {:ok, _} = Machines.start(runtime, handle, grown.version)
    assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 10_000)
    assert {:ok, cmd} = Machines.submit(runtime, handle, %{f.spec | id: "after-growth"})
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, cmd, 10_000)
    {:ok, idle} = Machines.await(runtime, handle, 10_000)
    assert {:ok, measured} = Machines.measurements(runtime, handle)
    assert measured.machine.storage_gb == 3
    assert {:ok, _} = Machines.stop(runtime, handle, idle.version)
    assert {:ok, %{state: :stopped} = stopped} = Machines.await(runtime, handle, 10_000)
    assert {:ok, _} = Machines.delete(runtime, handle, stopped.version)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 10_000)
    assert {:ok, %{disk_gb: 0}} = Memory.usage(f.store, "peer")

    assert {:ok, duplicate} =
             Machines.expand_disks(runtime, handle, "bigger", created.version,
               storage_gb: 3,
               overlay_gb: 2
             )

    assert duplicate.state == :deleted and resize_count(f) == 1
  end

  test "a lost response is not replayed after restart or resolved by a stopped observation" do
    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10), resize_lost: true)
    {handle, created} = machine(f)
    {:ok, _} = Machines.expand_disks(f.runtime, handle, "lost", created.version, storage_gb: 4)
    assert {:ok, %{state: :unknown}} = Machines.await(f.runtime, handle, 10_000)
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 30_000)
    assert :ok = Machines.reconcile(runtime, handle)
    {:ok, unknown} = Machines.inspect(runtime, handle)
    assert {:error, _} = Machines.start(runtime, handle, unknown.version)
    assert {:error, _} = Machines.resolve(runtime, handle, unknown.version, quiesced: true)
    {:ok, fresh} = Machines.inspect(runtime, handle)

    assert {:error, _} =
             Machines.resolve_disk_expansion(runtime, handle, "lost", fresh.version,
               quiesced: false
             )

    assert {:ok, resolved} =
             Machines.resolve_disk_expansion(runtime, handle, "lost", fresh.version,
               quiesced: true
             )

    assert resolved.disk_expansions["lost"].state == :resolved
    assert resolved.reservation.disk_gb == 5 and resize_count(f) == 1
  end

  test "partial growth cannot release capacity; deletion resolution requires verified absence" do
    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10), resize_partial: true)
    {handle, created} = machine(f)

    {:ok, _} =
      Machines.expand_disks(f.runtime, handle, "partial", created.version,
        storage_gb: 3,
        overlay_gb: 4
      )

    {:ok, unknown} = Machines.await(f.runtime, handle, 10_000)
    assert unknown.state == :unknown

    assert {:error, _} =
             Machines.resolve_disk_expansion(f.runtime, handle, "partial", unknown.version,
               quiesced: true
             )

    {:ok, fresh} = Machines.inspect(f.runtime, handle)

    assert {:error, _} =
             Machines.resolve_disk_expansion(f.runtime, handle, "partial", fresh.version,
               quiesced: true,
               disposition: :deleted
             )

    assert {:ok, %{disk_gb: 7}} = Memory.usage(f.store, "peer")
    Agent.update(f.peer, &%{&1 | machines: %{}})
    {:ok, fresh} = Machines.inspect(f.runtime, handle)

    assert {:ok, %{state: :deleted}} =
             Machines.resolve_disk_expansion(f.runtime, handle, "partial", fresh.version,
               quiesced: true,
               disposition: :deleted
             )

    assert {:ok, %{disk_gb: 0}} = Memory.usage(f.store, "peer")
  end

  test "ownership mismatch sends no resize" do
    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10))
    {handle, created} = machine(f)

    Agent.update(f.peer, fn s ->
      %{
        s
        | machines:
            Map.update!(
              s.machines,
              created.machine_name,
              &Map.update!(&1, "createdAt", fn n -> n + 1 end)
            )
      }
    end)

    {:ok, _} =
      Machines.expand_disks(f.runtime, handle, "mismatch", created.version, storage_gb: 3)

    assert {:ok, %{state: :unknown, last_error: %{category: :identity_conflict}}} =
             Machines.await(f.runtime, handle, 10_000)

    assert resize_count(f) == 0
  end

  test "running machines reject growth" do
    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10))
    {handle, created} = machine(f)
    {:ok, _} = Machines.start(f.runtime, handle, created.version)
    {:ok, running} = Machines.await(f.runtime, handle, 10_000)

    assert {:error, %{category: :admission_exhausted}} =
             Machines.expand_disks(f.runtime, handle, "running", running.version, storage_gb: 3)

    assert resize_count(f) == 0
  end

  for {event, phase, state, count} <- [
        {:expansion_intent, :before, :unknown, 0},
        {:expansion_intent, :after, :unknown, 0},
        {:expansion_receipt, :before, :unknown, 1},
        {:expansion_receipt, :after, :completed, 1}
      ] do
    test "store failure #{event}/#{phase} preserves intent and never replays" do
      observer = self()
      event = unquote(event)
      phase = unquote(phase)

      gate =
        start_supervised!({Agent, fn -> %{failure: {event, phase}, observer: observer} end},
          id: :failure
        )

      f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10), faults: gate)
      {handle, created} = machine(f)

      {:ok, _} =
        Machines.expand_disks(f.runtime, handle, "store-failure", created.version, storage_gb: 3)

      assert_receive {:store_failure, ^event, ^phase}, 5000
      {:ok, record} = Machines.await(f.runtime, handle, 10_000)
      assert record.disk_expansions["store-failure"].state == unquote(state)
      assert resize_count(f) == unquote(count)
      assert {:ok, %{disk_gb: 4}} = Memory.usage(f.store, "peer")
    end
  end

  test "controller death after worker growth and before receipt persistence does not replay" do
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :expansion_receipt, phase: :before, observer: observer, fired: false} end},
        id: :gate
      )

    f = RuntimeFixture.start(__MODULE__, capacity: Contract.capacity(10), faults: gate)
    {handle, created} = machine(f)
    {:ok, _} = Machines.expand_disks(f.runtime, handle, "crash", created.version, storage_gb: 3)
    assert_receive {:boundary, :expansion_receipt, :before, _}, 5000
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 30_000)
    assert {:ok, %{state: :unknown} = record} = Machines.await(runtime, handle, 10_000)
    assert record.disk_expansions["crash"].state == :unknown
    assert resize_count(f) == 1
    assert {:ok, %{disk_gb: 4}} = Memory.usage(f.store, "peer")
  end

  defp resize_count(f),
    do:
      Enum.count(ManagedPeer.snapshot(f.peer).operations, fn {_, p} ->
        String.ends_with?(p, "/resize")
      end)
end
