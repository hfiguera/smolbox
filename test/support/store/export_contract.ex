defmodule SmolBox.Store.ExportContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{ExportDestination, ExportSpec, ManagedMachine}
  alias SmolBox.Store.{Contract, MachineContract}

  def spec(id \\ "export-one", tag \\ "export-one") do
    {:ok, destination} =
      ExportDestination.new(
        id: "exports",
        registry: "registry.example.com",
        repository: "team/exports",
        credential_ref: "publisher",
        immutable_tags: true,
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    {:ok, spec} = ExportSpec.new(id: id, tag: tag, destination: destination)
    spec
  end

  def stopped(adapter, store, id \\ "computer") do
    record = MachineContract.running_named(adapter, store, id)

    {:ok, stopped} =
      adapter.machine(store, :write, [
        ManagedMachine.key(record),
        Contract.guard(record),
        [state: :stopped, observed_machine: %{record.observed_machine | state: :stopped}],
        1000
      ])

    stopped
  end

  def accept(adapter, store, machine, spec \\ spec()) do
    {:ok, fingerprint} =
      ExportSpec.fingerprint(spec, ManagedMachine.key(machine), :binary.copy(<<1>>, 32))

    adapter.machine(store, :export_accept, [
      ManagedMachine.key(machine),
      spec,
      fingerprint,
      %{slots: 20, cpus: 64, memory_mb: 65_536, disk_gb: 1024},
      1100
    ])
  end

  def admission(adapter, store) do
    running = MachineContract.running(adapter, store)
    assert {:error, _} = accept(adapter, store, running)

    {:ok, machine} =
      adapter.machine(store, :write, [
        ManagedMachine.key(running),
        Contract.guard(running),
        [state: :stopped, observed_machine: %{running.observed_machine | state: :stopped}],
        1000
      ])

    assert {:ok, active} = accept(adapter, store, machine)
    assert {:ok, ^active} = accept(adapter, store, active)
    assert active.active_export == "export-one"
    assert active.exports["export-one"].state == :accepted

    assert {:error, %{category: :identity_conflict}} =
             accept(adapter, store, active, spec("export-one", "changed"))

    assert {:error, _} = accept(adapter, store, active, spec("second", "second"))

    for action <- [:start, :stop, :delete] do
      assert {:error, %{category: :admission_exhausted}} =
               adapter.machine(store, :request, [
                 ManagedMachine.key(active),
                 action,
                 active.version,
                 1100
               ])
    end

    assert {:ok, %{slots: 2, cpus: 5, disk_gb: 130}} = adapter.usage(store, "worker")
    assert active.reservation == machine.reservation
  end

  def cancellation(adapter, store) do
    machine = stopped(adapter, store)
    assert {:ok, active} = accept(adapter, store, machine)

    assert {:ok, cancelled} =
             adapter.machine(store, :export_cancel, [
               ManagedMachine.key(active),
               "export-one",
               1200
             ])

    assert cancelled.exports["export-one"].state == :cancelled
    assert ManagedMachine.idle?(cancelled)
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
    assert {:ok, ^cancelled} = accept(adapter, store, cancelled)
    assert {:error, _} = accept(adapter, store, cancelled, spec("another", "export-one"))
    # The platform tag is also a permanent publication claim.
    assert {:error, _} =
             accept(adapter, store, cancelled, spec("another", "export-one-linux-amd64"))
  end

  def uncertainty(adapter, store) do
    machine = stopped(adapter, store)
    assert {:ok, active} = accept(adapter, store, machine)
    key = ManagedMachine.key(active)

    assert {:ok, intent} =
             adapter.machine(store, :export_advance, [
               key,
               Contract.guard(active),
               "export-one",
               :accepted,
               [state: :dispatching],
               1200
             ])

    assert {:ok, unknown} = adapter.machine(store, :export_cancel, [key, "export-one", 1300])
    assert unknown.exports["export-one"].state == :unknown
    assert {:ok, %{slots: 2, disk_gb: 130}} = adapter.usage(store, "worker")

    assert {:error, _} =
             adapter.machine(store, :resolve, [
               key,
               Contract.guard(unknown),
               unknown.observed_machine,
               1300
             ])

    assert {:error, _} =
             adapter.machine(store, :export_advance, [
               key,
               Contract.guard(intent),
               "export-one",
               :dispatching,
               [state: :failed],
               1300
             ])

    assert {:ok, _lease} = adapter.claim_worker(store, "worker", "new-owner", 7000, 5000)
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "new-owner", 7000, 5000])

    assert {:error, _} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(claimed),
               "export-one",
               %{claimed.observed_machine | created_at: 999},
               7000
             ])

    assert {:ok, resolved} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(claimed),
               "export-one",
               claimed.observed_machine,
               7000
             ])

    assert resolved.exports["export-one"].state == :resolved_unknown
    assert resolved.exports["export-one"].result == nil
    assert resolved.state == :stopped
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end

  def competition(adapter, store) do
    machine = stopped(adapter, store)

    results =
      1..12
      |> Task.async_stream(
        fn n -> accept(adapter, store, machine, spec("export-#{n}", "tag-#{n}")) end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert map_size(winner.exports) == 1
    assert {:ok, %{slots: 2, disk_gb: 130}} = adapter.usage(store, "worker")

    for n <- 1..3 do
      assert {:error, _} =
               adapter.machine(store, :submit, [
                 ManagedMachine.key(winner),
                 Contract.record("command-#{n}"),
                 10,
                 1100
               ])
    end
  end

  def lifecycle_race(adapter, store) do
    machine = stopped(adapter, store)

    results =
      [
        fn -> accept(adapter, store, machine) end,
        fn ->
          adapter.machine(store, :request, [
            ManagedMachine.key(machine),
            :delete,
            machine.version,
            1100
          ])
        end
      ]
      |> Task.async_stream(& &1.(), max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    slots = if winner.active_export, do: 2, else: 1
    assert {:ok, %{slots: ^slots}} = adapter.usage(store, "worker")
  end

  def destination_race(adapter, store) do
    machines = for id <- ["source-one", "source-two"], do: stopped(adapter, store, id)

    results =
      machines
      |> Task.async_stream(&accept(adapter, store, &1))
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:ok, %{slots: 3, disk_gb: 132}} = adapter.usage(store, "worker")

    assert {:ok, cancelled} =
             adapter.machine(store, :export_cancel, [
               ManagedMachine.key(winner),
               "export-one",
               1200
             ])

    assert {:ok, %{slots: 2, disk_gb: 4}} = adapter.usage(store, "worker")
    other = Enum.find(machines, &(&1.id != cancelled.id))
    assert {:error, _} = accept(adapter, store, other)
  end

  def unsafe_release(adapter, store) do
    machine = stopped(adapter, store)
    {:ok, active} = accept(adapter, store, machine)
    key = ManagedMachine.key(machine)

    {:ok, dispatched} =
      adapter.machine(store, :export_advance, [
        key,
        Contract.guard(active),
        "export-one",
        :accepted,
        [state: :dispatching],
        1200
      ])

    for changes <- [
          [state: :failed],
          [
            state: :failed,
            error: %SmolBox.Error{category: :unknown, operation: :export, evidence: :unknown}
          ]
        ] do
      assert {:error, _} =
               adapter.machine(store, :export_advance, [
                 key,
                 Contract.guard(dispatched),
                 "export-one",
                 :dispatching,
                 changes,
                 1300
               ])
    end

    assert {:ok, %{slots: 2}} = adapter.usage(store, "worker")
    assert {:ok, ^dispatched} = adapter.machine(store, :fetch, [key])
  end

  defmacro __using__(options) do
    quote do
      use ExUnit.Case, unquote(options)

      for scenario <- [
            :admission,
            :cancellation,
            :uncertainty,
            :competition,
            :lifecycle_race,
            :unsafe_release,
            :destination_race
          ] do
        @export_scenario scenario
        test "export contract: #{scenario}", %{adapter: adapter, store: store} do
          apply(SmolBox.Store.ExportContract, @export_scenario, [adapter, store])
        end
      end
    end
  end
end
