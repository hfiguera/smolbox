defmodule SmolBox.Store.PortContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{ManagedMachine, PortMapping}
  alias SmolBox.Store.{Contract, MachineContract}

  def ports, do: [%PortMapping{host: 28_731, guest: 8000}]

  def claim(adapter, store, id, mappings \\ ports()) do
    record = MachineContract.record(id, mappings)
    assert {:ok, _} = adapter.machine(store, :accept, [record, 20])

    assert {:ok, claimed} =
             adapter.machine(store, :claim, [ManagedMachine.key(record), "owner", 1000, 5000])

    claimed
  end

  def reserve(adapter, store, record, worker \\ "worker") do
    adapter.machine(store, :reserve, [
      ManagedMachine.key(record),
      Contract.guard(record),
      {worker, "vm-" <> record.id, Contract.capacity(20)},
      1000
    ])
  end

  def competition(adapter, store) do
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 5000)
    claims = for n <- 1..8, do: claim(adapter, store, "ports-#{n}")

    results =
      claims
      |> Task.async_stream(&reserve(adapter, store, &1), max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert 7 == Enum.count(results, &match?({:error, %{category: :port_conflict}}, &1))
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")

    for loser <- Enum.reject(claims, &(&1.id == winner.id)) do
      assert {:ok, ^loser} = adapter.machine(store, :fetch, [ManagedMachine.key(loser)])
    end

    # A partial multi-port allocation must roll back the earlier free port too.
    partial =
      claim(adapter, store, "partial", [%PortMapping{host: 28_730, guest: 8000} | ports()])

    assert {:error, %{category: :port_conflict}} = reserve(adapter, store, partial)
    free = claim(adapter, store, "free", [%PortMapping{host: 28_730, guest: 8000}])
    assert {:ok, _} = reserve(adapter, store, free)
    assert {:ok, _} = adapter.claim_worker(store, "another-worker", "owner", 1000, 5000)
    assert {:ok, _} = reserve(adapter, store, partial, "another-worker")
  end

  def retention(adapter, store) do
    machine = MachineContract.running(adapter, store, ports())
    key = ManagedMachine.key(machine)
    contender = claim(adapter, store, "contender")

    retained =
      Enum.reduce([:stopped, :missing, :unknown], machine, fn state, current ->
        assert {:ok, next} =
                 adapter.machine(store, :write, [
                   key,
                   Contract.guard(current),
                   [state: state],
                   1100
                 ])

        assert next.reserved_ports == [28_731]
        assert {:error, %{category: :port_conflict}} = reserve(adapter, store, contender)
        next
      end)

    assert {:error, _} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(retained),
               [state: :deleted],
               1100
             ])

    assert {:ok, deleted} =
             adapter.machine(store, :resolve, [key, Contract.guard(retained), :absent, 1100])

    assert deleted.reserved_ports == [] and deleted.reservation == nil

    assert {:ok, ^deleted} =
             adapter.machine(store, :accept, [MachineContract.record("computer", ports()), 20])

    assert {:ok, _} = reserve(adapter, store, contender)
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
  end

  def completion(adapter, store) do
    machine = MachineContract.running(adapter, store, ports())
    key = ManagedMachine.key(machine)
    command = Contract.record()
    assert {:ok, accepted} = adapter.machine(store, :submit, [key, command, 20, 1100])
    assert accepted.created_machine.ports == ports()
    assert {:ok, cancelled} = adapter.cancel(store, {command.scope, command.id}, 1100)
    assert {:ok, claimed} = adapter.claim(store, {command.scope, command.id}, "owner", 1100, 5000)
    assert claimed.cancel_requested_at_ms == cancelled.cancel_requested_at_ms

    assert {:ok, done} =
             adapter.write(
               store,
               {command.scope, command.id},
               Contract.guard(claimed),
               [state: :cancelled],
               1100
             )

    assert {:ok, _} =
             adapter.machine(store, :finish, [
               {command.scope, command.id},
               Contract.guard(done),
               1100
             ])

    assert {:ok, idle} = adapter.machine(store, :fetch, [key])
    assert idle.reserved_ports == [28_731] and idle.active_execution == nil
    contender = claim(adapter, store, "after-command")
    assert {:error, %{category: :port_conflict}} = reserve(adapter, store, contender)
  end
end
