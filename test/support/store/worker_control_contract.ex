defmodule SmolBox.Store.WorkerControlContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Execution, ManagedMachine}
  alias SmolBox.Store.{BranchContract, CaptureContract, Contract, ExportContract, MachineContract}

  defmacro __using__(options) do
    cases =
      for {label, function} <- [
            {"durable worker modes use versions and reject stale resume", :versions},
            {"draining atomically rejects both reservation kinds without releasing existing capacity",
             :admission},
            {"competing admission and drain serialize and later reservations cannot slip through",
             :race},
            {"maintenance pages include all scopes without command contents or shutdown clearance",
             :inventory},
            {"new helper allocations are blocked but duplicate history remains available",
             :helpers}
          ] do
        quote do
          test unquote(label), %{adapter: adapter, store: store} do
            SmolBox.Store.WorkerControlContract.unquote(function)(adapter, store)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(cases)
    end
  end

  def versions(adapter, store) do
    assert {:ok, %{mode: :active, version: 0}} = adapter.worker_control(store, "worker")
    assert {:ok, drained} = adapter.set_worker_mode(store, "worker", :draining, :any, 1000)
    assert drained.version == 1
    assert {:ok, ^drained} = adapter.set_worker_mode(store, "worker", :draining, :any, 1100)
    assert {:ok, active} = adapter.set_worker_mode(store, "worker", :active, 1, 1200)
    assert active.version == 2
    assert {:ok, ^active} = adapter.set_worker_mode(store, "worker", :active, 1, 1300)
    assert {:ok, %{version: 3}} = adapter.set_worker_mode(store, "worker", :draining, :any, 1400)

    assert {:error, %{category: :stale_version}} =
             adapter.set_worker_mode(store, "worker", :active, 1, 1500)

    assert {:error, %{category: :validation}} =
             adapter.set_worker_mode(store, "worker", :active, :any, 1500)

    assert {:ok, %{mode: :draining}} = adapter.worker_control(store, "worker")
    assert {:ok, _} = adapter.claim_worker(store, "worker", "replacement", 9000, 1000)
    assert {:ok, %{mode: :draining}} = adapter.worker_control(store, "worker")
  end

  def admission(adapter, store) do
    owned = MachineContract.running(adapter, store)
    key = ManagedMachine.key(owned)
    {:ok, used} = adapter.usage(store, "worker")
    execution = pending(adapter, store, "pending")
    machine = MachineContract.record("next")
    {:ok, _} = adapter.machine(store, :accept, [machine, 10])

    {:ok, claimed} =
      adapter.machine(store, :claim, [ManagedMachine.key(machine), "owner", 1100, 1000])

    assert {:ok, _} = adapter.set_worker_mode(store, "worker", :draining, :any, 1100)
    assert {:error, %{category: :admission_exhausted}} = reserve(adapter, store, execution)

    assert {:error, %{category: :admission_exhausted}} =
             adapter.machine(store, :reserve, [
               ManagedMachine.key(machine),
               Contract.guard(claimed),
               {"worker", "next-vm", Contract.capacity(20)},
               1100
             ])

    assert {:ok, ^used} = adapter.usage(store, "worker")
    assert {:ok, %{worker_id: nil}} = adapter.fetch(store, Execution.key(execution))
    # Existing work and cleanup do not lose their lease or lifecycle rights.
    assert {:ok, _} = adapter.machine(store, :submit, [key, Contract.record("command"), 10, 1100])

    assert {:ok, %{active_execution: {"contract", "command"}}} =
             adapter.machine(store, :fetch, [key])

    assert {:ok, _} = adapter.cancel(store, {"contract", "command"}, 1200)
    assert {:ok, ^used} = adapter.usage(store, "worker")
  end

  def race(adapter, store) do
    {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 5000)
    record = pending(adapter, store, "race")
    owner = self()

    tasks =
      for action <- [:drain, :reserve] do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :go -> :ok
          end

          compete(action, adapter, store, record)
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}, 5000
      send(pid, :go)
    end

    [drained, admitted] = Enum.map(tasks, &Task.await(&1, 10_000))
    assert {:ok, %{mode: :draining}} = drained

    assert match?({:ok, _}, admitted) or
             match?({:error, %{category: :admission_exhausted}}, admitted)

    {:ok, used} = adapter.usage(store, "worker")
    assert used.slots == if(match?({:ok, _}, admitted), do: 1, else: 0)
    next = pending(adapter, store, "after-drain")
    assert {:error, %{category: :admission_exhausted}} = reserve(adapter, store, next)
    assert {:ok, ^used} = adapter.usage(store, "worker")
  end

  def inventory(adapter, store) do
    first = MachineContract.running_named(adapter, store, "first")
    second = MachineContract.running_named(adapter, store, "second")
    pending = pending(adapter, store, "private-command", "other-scope")
    {:ok, _} = reserve(adapter, store, pending)
    {:ok, _} = adapter.set_worker_mode(store, "worker", :draining, :any, 1100)
    {:ok, page} = adapter.worker_maintenance(store, "worker", nil, 1, 1200)
    assert [%{kind: :execution, id: "private-command", scope: "other-scope"}] = page.records
    assert page.assessment == :blocked and page.reserved.slots == 3
    refute inspect(page) =~ "private-input-for-drain"
    {:ok, next} = adapter.worker_maintenance(store, "worker", page.next_cursor, 1, 1200)
    assert [%{kind: :machine, id: id}] = next.records
    assert id == first.id
    {:ok, last} = adapter.worker_maintenance(store, "worker", next.next_cursor, 1, 1200)
    assert [%{id: id}] = last.records
    assert id == second.id and last.next_cursor == nil

    assert {:error, %{category: :validation}} =
             adapter.worker_maintenance(store, "worker", :bad, 1, 1200)

    {:ok, _} = adapter.set_worker_mode(store, "empty", :draining, :any, 1200)

    assert {:ok, %{assessment: :operator_quiescence_required, records: []}} =
             adapter.worker_maintenance(store, "empty", nil, 20, 1200)
  end

  def helpers(adapter, store) do
    branch = BranchContract.running(adapter, store)
    capture = CaptureContract.running(adapter, store)
    export = ExportContract.stopped(adapter, store, "export")
    {:ok, _} = adapter.set_worker_mode(store, "worker", :draining, :any, 1100)

    for outcome <- [
          BranchContract.accept(adapter, store, branch),
          CaptureContract.accept(adapter, store, capture),
          ExportContract.accept(adapter, store, export)
        ] do
      assert {:error, %{category: :admission_exhausted}} = outcome
    end

    assert {:ok, %{slots: 3}} = adapter.usage(store, "worker")
    {:ok, _} = adapter.set_worker_mode(store, "worker", :active, 1, 1100)
    {:ok, child} = BranchContract.accept(adapter, store, branch)
    {:ok, captured} = CaptureContract.accept(adapter, store, capture)
    {:ok, exported} = ExportContract.accept(adapter, store, export)
    {:ok, _} = adapter.set_worker_mode(store, "worker", :draining, :any, 1100)
    assert {:ok, ^child} = BranchContract.accept(adapter, store, branch)
    assert {:ok, ^captured} = CaptureContract.accept(adapter, store, capture)
    assert {:ok, ^exported} = ExportContract.accept(adapter, store, export)
  end

  defp compete(:drain, adapter, store, _record),
    do: adapter.set_worker_mode(store, "worker", :draining, :any, 1100)

  defp compete(:reserve, adapter, store, record), do: reserve(adapter, store, record)

  defp pending(adapter, store, id, scope \\ "contract") do
    spec = %{Contract.record(id, ["echo", "private-input-for-drain"]).spec | scope: scope}
    {:ok, fingerprint} = SmolBox.ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)
    {:ok, _, :inserted} = adapter.accept(store, record, 10)
    {:ok, claimed} = adapter.claim(store, Execution.key(record), "owner", 1000, 5000)
    claimed
  end

  defp reserve(adapter, store, record),
    do:
      adapter.reserve(
        store,
        Execution.key(record),
        Contract.guard(record),
        {"worker", "vm-" <> record.id, Contract.capacity(20)},
        1100
      )
end
