defmodule SmolBox.Store.MachineContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Error, Execution, Machine, ManagedMachine, ManagedMachineSpec, Result}
  alias SmolBox.Store.Contract

  def record(id \\ "computer") do
    execution = Contract.record()

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "contract",
        id: id,
        artifact: execution.spec.artifact,
        profile: execution.spec.profile
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    record
  end

  def running(adapter, store) do
    record = record()
    key = ManagedMachine.key(record)
    assert {:ok, _} = adapter.machine(store, :accept, [record, 10])
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 5000)
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1000, 5000])

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {"worker", "persistent-vm", Contract.capacity()},
               1000
             ])

    observed = %Machine{
      name: reserved.machine_name,
      state: :running,
      created_at: 1000,
      cpus: 1,
      memory_mb: 256,
      storage_gb: 1,
      overlay_gb: 1
    }

    assert {:ok, running} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(reserved),
               [
                 state: :running,
                 operation: nil,
                 phase: nil,
                 created_machine: observed,
                 observed_machine: observed
               ],
               1000
             ])

    running
  end

  def acceptance(adapter, store) do
    record = record()

    results =
      1..12
      |> Task.async_stream(fn _ -> adapter.machine(store, :accept, [record, 1]) end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, ^record}, &1))

    assert {:error, %Error{category: :identity_conflict}} =
             adapter.machine(store, :accept, [
               %{record | fingerprint: String.duplicate("a", 64)},
               1
             ])

    assert {:error, %Error{category: :admission_exhausted}} =
             adapter.machine(store, :accept, [record("two"), 1])

    assert {:ok, [^record], nil} = adapter.machine(store, :list, [record.scope, nil, 1])
    assert {:ok, [], nil} = adapter.machine(store, :list, ["another", nil, 1])
  end

  def shared_capacity(adapter, store) do
    machine = running(adapter, store)
    command = Contract.record()
    assert {:ok, _, :inserted} = adapter.accept(store, command, 10)
    assert {:ok, claimed} = adapter.claim(store, Execution.key(command), "owner", 1000, 5000)

    assert {:error, %Error{category: :admission_exhausted}} =
             adapter.reserve(
               store,
               Execution.key(command),
               Contract.guard(claimed),
               {"worker", "other-vm", Contract.capacity()},
               1000
             )

    assert {:error, %Error{category: :identity_conflict}} =
             adapter.reserve(
               store,
               Execution.key(command),
               Contract.guard(claimed),
               {"worker", machine.machine_name, Contract.capacity(2)},
               1000
             )

    assert {:ok, ^machine} = adapter.find_machine(store, "worker", machine.machine_name)
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end

  def command_admission(adapter, store) do
    machine = running(adapter, store)
    key = ManagedMachine.key(machine)

    results =
      1..12
      |> Task.async_stream(
        fn n ->
          adapter.machine(store, :submit, [key, Contract.record("command-#{n}"), 20, 1100])
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, accepted}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert accepted.managed_machine == key and accepted.reservation == nil

    assert {:ok, ^accepted} =
             adapter.machine(store, :submit, [key, Contract.record(accepted.id), 20, 1100])

    assert {:error, %Error{category: :identity_conflict}} =
             adapter.machine(store, :submit, [
               key,
               Contract.record(accepted.id, ["false"]),
               20,
               1100
             ])

    assert {:ok, busy} = adapter.machine(store, :fetch, [key])

    for action <- [:stop, :delete] do
      assert {:error, %Error{category: :admission_exhausted}} =
               adapter.machine(store, :request, [key, action, busy.version, 1100])
    end

    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
  end

  def lifecycle_race(adapter, store) do
    machine = running(adapter, store)
    key = ManagedMachine.key(machine)

    results =
      [
        fn -> adapter.machine(store, :request, [key, :stop, machine.version, 1100]) end,
        fn -> adapter.machine(store, :submit, [key, Contract.record(), 10, 1100]) end
      ]
      |> Task.async_stream(& &1.(), max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [_success] = Enum.filter(results, &match?({:ok, _}, &1))
  end

  def completion(adapter, store) do
    machine = running(adapter, store)
    key = ManagedMachine.key(machine)
    command = dispatched(adapter, store, key)

    assert {:ok, collecting} =
             adapter.write(
               store,
               Execution.key(command),
               Contract.guard(command),
               [
                 state: :collecting,
                 evidence: :exited,
                 result: %Result{exit_code: 0, stdout: "ok", stderr: ""}
               ],
               1100
             )

    assert {:ok, completed} =
             adapter.write(
               store,
               Execution.key(command),
               Contract.guard(collecting),
               [state: :completed, collection: :complete],
               1100
             )

    assert {:ok, clean} =
             adapter.machine(store, :finish, [
               Execution.key(command),
               Contract.guard(completed),
               1100
             ])

    assert clean.cleanup == :complete and clean.absence_at_ms == nil
    assert {:ok, idle} = adapter.machine(store, :fetch, [key])
    assert idle.active_execution == nil and idle.reservation == machine.reservation
    assert {:ok, _} = adapter.machine(store, :submit, [key, Contract.record("next"), 10, 1100])

    assert {:error, %Error{category: :stale_claim}} =
             adapter.claim(store, Execution.key(command), "owner", 1100, 1000)
  end

  def uncertainty(adapter, store) do
    machine = running(adapter, store)
    key = ManagedMachine.key(machine)
    command = dispatched(adapter, store, key)

    assert {:ok, unknown} =
             adapter.write(
               store,
               Execution.key(command),
               Contract.guard(command),
               [state: :unknown, evidence: :unknown],
               1100
             )

    assert {:ok, blocked} =
             adapter.machine(store, :finish, [
               Execution.key(command),
               Contract.guard(unknown),
               1100
             ])

    assert blocked.cleanup == :failed
    assert {:ok, machine} = adapter.machine(store, :claim, [key, "owner", 1100, 5000])

    assert {:error, _} =
             adapter.machine(store, :resolve, [
               key,
               Contract.guard(machine),
               machine.observed_machine,
               1100
             ])

    stopped = %{machine.observed_machine | state: :stopped}

    assert {:ok, resolved} =
             adapter.machine(store, :resolve, [key, Contract.guard(machine), stopped, 1100])

    assert resolved.active_execution == nil and resolved.state == :stopped
    assert {:ok, preserved} = adapter.fetch(store, Execution.key(command))

    assert preserved.state == :unknown and preserved.result == nil and
             preserved.cleanup == :complete

    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
  end

  def takeover(adapter, store) do
    machine = running(adapter, store)
    key = ManagedMachine.key(machine)
    assert {:ok, _} = adapter.claim_worker(store, "worker", "replacement", 7000, 5000)

    assert {:error, %Error{category: :stale_claim}} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(machine),
               [state: :stopped],
               7000
             ])

    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "replacement", 7000, 5000])
    assert claimed.generation > machine.generation
    assert claimed.reservation == machine.reservation

    assert {:error, %Error{category: :stale_version}} =
             adapter.machine(store, :request, [key, :delete, machine.version, 7000])

    assert {:ok, deletion} =
             adapter.machine(store, :request, [key, :delete, claimed.version, 7000])

    assert {:error, _} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(deletion),
               [state: :deleted, operation: nil, phase: nil],
               7000
             ])

    assert {:ok, gone} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(deletion),
               [state: :deleted, operation: nil, phase: nil, absence_at_ms: 7000],
               7000
             ])

    assert gone.reservation == nil
    assert {:ok, %{slots: 0}} = adapter.usage(store, "worker")
    assert {:ok, ^gone} = adapter.find_machine(store, "worker", machine.machine_name)
  end

  defp dispatched(adapter, store, machine_key) do
    assert {:ok, command} =
             adapter.machine(store, :submit, [machine_key, Contract.record(), 10, 1100])

    key = Execution.key(command)
    assert {:ok, command} = adapter.claim(store, key, "owner", 1100, 5000)

    Enum.reduce(
      [
        [state: :preparing],
        [state: :ready],
        [state: :dispatching, evidence: :dispatch_uncertain]
      ],
      command,
      fn changes, current ->
        assert {:ok, next} = adapter.write(store, key, Contract.guard(current), changes, 1100)
        next
      end
    )
  end
end
