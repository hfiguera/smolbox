defmodule SmolBox.Store.BackendContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.Identity
  alias SmolBox.Store.{Contract, MachineContract}

  alias SmolBox.{Execution, Machine, ManagedMachine}

  defmacro __using__(options) do
    cases =
      for {title, function} <- [
            {"backend enrollment is idempotent and native domains cannot create duplicate capacity pools",
             :enrollment},
            {"native intent and capacity commit together while failed admission retains neither",
             :admission},
            {"legacy HTTP assignments and released tombstones fence backend reassignment",
             :legacy},
            {"HTTP reservation and native enrollment serialize without crossing backend kinds",
             :race},
            {"retained native reservation saves intent and cannot switch domains", :retained},
            {"native recovery pages retain tombstones and advance through unassigned records",
             :assignment_pages},
            {"native recovery pages validate bounded cursors without mutating the store",
             :invalid_pages},
            {"native recovery cursors retain byte ordering through empty authority pages",
             :page_order}
          ] do
        quote do
          test unquote(title), %{adapter: adapter, store: store} do
            SmolBox.Store.BackendContract.unquote(function)(adapter, store)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      unquote_splicing(cases)
    end
  end

  def domain_binding(worker \\ "worker", generation \\ "a"),
    do: %Binding{kind: :embedded, target_id: worker, generation: String.duplicate(generation, 32)}

  def assignment(record, name, binding \\ domain_binding()) do
    profile = record.spec.profile

    %Assignment{
      binding: binding,
      creation: %{
        "name" => name,
        "owner_token" => String.duplicate("b", 64),
        "incarnation" => String.duplicate("c", 32),
        "artifact" => %{
          "path" => "/approved/offline.smolmachine",
          "sha256" => record.spec.artifact["sha256"],
          "max_bytes" => 16_777_216,
          "guest_platform" => "linux/amd64"
        },
        "resources" => %{
          "cpus" => profile.cpus,
          "memory_mib" => profile.memory_mb,
          "storage_gib" => profile.storage_gb,
          "overlay_gib" => profile.overlay_gb
        },
        "labels" => %{}
      }
    }
  end

  def enrollment(adapter, store) do
    native = domain_binding()
    assert {:ok, %{backend_bindings: 1}} = adapter.capabilities(store)
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)

    assert {:error, %{category: :identity_conflict}} =
             adapter.bind_backend(store, "other", domain_binding("other"))

    assert {:error, _} = adapter.bind_backend(store, "other", native)
    assert {:ok, :http} = adapter.bind_backend(store, "other", :http)
    assert {:error, _} = adapter.bind_backend(store, "bad", :k8s)
    # An empty authority can be changed after the caller establishes quiescence.
    assert {:ok, :http} = adapter.bind_backend(store, "worker", :http)
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)
  end

  def assignment_pages(adapter, store) do
    assert {:ok, %{backend_recovery: 1}} = adapter.capabilities(store)
    assert {:ok, _} = adapter.bind_backend(store, "worker", domain_binding())
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)
    unassigned = pending(adapter, store, "a-unassigned")
    first = pending(adapter, store, "b-tombstone")
    intent = assignment(first, "native-tombstone")
    assert {:ok, reserved} = reserve(adapter, store, first, intent)

    assert {:ok, cleaned} =
             adapter.write(
               store,
               Execution.key(first),
               Contract.guard(reserved),
               [state: :failed, cleanup: :complete, absence_at_ms: 1300],
               1300
             )

    assert {:ok, released} =
             adapter.release(store, Execution.key(first), Contract.guard(cleaned), 1400)

    assert released.reservation == nil and released.backend_assignment == intent

    machine = MachineContract.record("retained-page")
    key = ManagedMachine.key(machine)
    assert {:ok, _} = adapter.machine(store, :accept, [machine, 10])
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1400, 10_000])
    intended = assignment(machine, "native-retained-page")

    assert {:ok, retained} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {"worker", "native-retained-page", Contract.capacity(), intended},
               1400
             ])

    assert {:ok, [], cursor = {0, "contract", "a-unassigned"}} =
             adapter.backend_assignments(store, "worker", nil, 1)

    assert {:ok, [^released], next = {0, "contract", "b-tombstone"}} =
             adapter.backend_assignments(store, "worker", cursor, 1)

    assert {:ok, [^retained], nil} = adapter.backend_assignments(store, "worker", next, 1)
    assert {:ok, [], ^cursor} = adapter.backend_assignments(store, "other", nil, 1)
    assert {:ok, ^unassigned} = adapter.fetch(store, Execution.key(unassigned))
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:ok, ^released} = adapter.fetch(store, Execution.key(first))
    assert {:ok, ^retained} = adapter.machine(store, :fetch, [key])
  end

  def invalid_pages(adapter, store) do
    for {worker, cursor, limit} <- [
          {"worker", nil, 0},
          {"worker", nil, 101},
          {"worker", {3, "scope", "id"}, 1},
          {"worker", {0, nil, "id"}, 1},
          {"worker", "opaque", 1},
          {"", nil, 1}
        ] do
      assert {:error, %{category: :validation}} =
               adapter.backend_assignments(store, worker, cursor, limit)
    end

    assert {:ok, [], nil} = adapter.backend_assignments(store, "worker", nil, 1)
    assert {:ok, %{slots: 0}} = adapter.usage(store, "worker")
  end

  def page_order(adapter, store) do
    ids = ["a_", "a.", "a", "A", "a-", "b"]
    for id <- ids, do: pending(adapter, store, id)

    final =
      Enum.reduce(Enum.sort(ids), nil, fn id, cursor ->
        assert {:ok, [], next} = adapter.backend_assignments(store, "worker", cursor, 1)
        assert next == if(id == "b", do: nil, else: {0, "contract", id})
        next
      end)

    assert final == nil
  end

  def admission(adapter, store) do
    native = domain_binding()
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)
    first = pending(adapter, store, "one")
    second = pending(adapter, store, "two")
    intended = assignment(first, "native-one")

    assert {:error, _} = reserve(adapter, store, first, nil)
    assert {:ok, ^first} = adapter.fetch(store, Execution.key(first))
    assert {:ok, reserved} = reserve(adapter, store, first, intended)
    assert reserved.backend_assignment == intended
    assert reserved.reservation == SmolBox.Profile.resources(first.spec.profile)
    assert {:ok, ^reserved} = adapter.fetch(store, Execution.key(first))

    assert {:error, %{category: :admission_exhausted}} =
             reserve(adapter, store, second, assignment(second, "native-two"))

    assert {:ok, ^second} = adapter.fetch(store, Execution.key(second))
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:error, _} = adapter.bind_backend(store, "worker", :http)
    assert {:error, _} = adapter.bind_backend(store, "worker", domain_binding("worker", "d"))
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)

    assert {:error, _} =
             adapter.release(store, Execution.key(reserved), Contract.guard(reserved), 1300)

    assert {:error, _} =
             adapter.write(
               store,
               Execution.key(reserved),
               Contract.guard(reserved),
               [backend_assignment: nil],
               1300
             )

    assert {:ok, ^reserved} = adapter.fetch(store, Execution.key(reserved))
  end

  def legacy(adapter, store) do
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = pending(adapter, store, "legacy")
    assert {:ok, reserved} = reserve(adapter, store, record, nil)
    assert {:error, _} = adapter.bind_backend(store, "worker", domain_binding())
    assert {:ok, :http} = adapter.bind_backend(store, "worker", :http)

    assert {:ok, cleaned} =
             adapter.write(
               store,
               Execution.key(record),
               Contract.guard(reserved),
               [state: :failed, cleanup: :complete, absence_at_ms: 1300],
               1300
             )

    assert {:ok, released} =
             adapter.release(store, Execution.key(record), Contract.guard(cleaned), 1400)

    assert released.reservation == nil
    assert {:ok, %{slots: 0}} = adapter.usage(store, "worker")
    assert {:error, _} = adapter.bind_backend(store, "worker", domain_binding())
  end

  def race(adapter, store) do
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = pending(adapter, store, "race")

    owner = self()

    tasks =
      for action <- [:bind, :reserve] do
        Task.async(fn ->
          send(owner, {:backend_ready, self()})

          receive do
            :go -> compete(action, adapter, store, record)
          after
            5000 -> raise "backend race barrier timed out"
          end
        end)
      end

    ready =
      for _task <- tasks do
        assert_receive {:backend_ready, pid}, 5000
        pid
      end

    Enum.each(ready, &send(&1, :go))

    outcomes = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, _}, &1)) == 1
    assert {:ok, current} = adapter.fetch(store, Execution.key(record))
    assert current.backend_assignment == nil
    assert {:ok, %{slots: slots}} = adapter.usage(store, "worker")
    assert slots == if(current.worker_id == nil, do: 0, else: 1)
  end

  defp compete(:bind, adapter, store, _record),
    do: adapter.bind_backend(store, "worker", domain_binding())

  defp compete(:reserve, adapter, store, record), do: reserve(adapter, store, record, nil)

  def retained(adapter, store) do
    native = domain_binding()
    assert {:ok, ^native} = adapter.bind_backend(store, "worker", native)
    assert {:ok, _} = adapter.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = MachineContract.record()
    key = ManagedMachine.key(record)
    assert {:ok, _} = adapter.machine(store, :accept, [record, 10])
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1100, 10_000])
    intended = assignment(record, "native-retained")

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {"worker", "native-retained", Contract.capacity(), intended},
               1200
             ])

    assert reserved.backend_assignment == intended
    assert {:ok, ^reserved} = adapter.machine(store, :fetch, [key])
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:error, _} = adapter.bind_backend(store, "worker", domain_binding("worker", "d"))

    observed = observation(reserved)

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
               1300
             ])

    assert {:ok, command} =
             adapter.machine(store, :submit, [key, Contract.record("native-command"), 10, 1300])

    assert command.backend_assignment == running.backend_assignment
    assert command.created_machine == observed and command.reservation == nil
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:ok, claimed} = adapter.claim(store, Execution.key(command), "owner", 1300, 10_000)

    dispatching =
      Enum.reduce(
        [
          [state: :preparing],
          [state: :ready],
          [state: :dispatching, evidence: :dispatch_uncertain]
        ],
        claimed,
        fn changes, current ->
          assert {:ok, next} =
                   adapter.write(
                     store,
                     Execution.key(command),
                     Contract.guard(current),
                     changes,
                     1350
                   )

          next
        end
      )

    assert {:ok, unknown} =
             adapter.write(
               store,
               Execution.key(command),
               Contract.guard(dispatching),
               [state: :unknown, evidence: :unknown],
               1400
             )

    assert {:ok, blocked} =
             adapter.machine(store, :finish, [
               Execution.key(command),
               Contract.guard(unknown),
               1400
             ])

    assert blocked.cleanup == :failed
    assert {:ok, machine} = adapter.machine(store, :fetch, [key])
    assert machine.state == :unknown and machine.active_execution == Execution.key(command)

    assert {:error, _} =
             adapter.machine(store, :submit, [key, Contract.record("after-unknown"), 10, 1500])

    stopped = %{
      observed
      | state: :stopped,
        backend_identity: %{observed.backend_identity | pid_identity: nil}
    }

    assert {:ok, resolved} =
             adapter.machine(store, :resolve, [key, Contract.guard(machine), stopped, 1500])

    assert resolved.state == :stopped and resolved.active_execution == nil
    assert resolved.backend_assignment == intended
    assert {:ok, %{slots: 1}} = adapter.usage(store, "worker")
    assert {:ok, saved} = adapter.fetch(store, Execution.key(command))

    assert saved.state == :unknown and saved.result == nil and
             saved.backend_assignment == intended
  end

  defp observation(record) do
    assignment = record.backend_assignment
    profile = record.spec.profile

    receipt =
      Map.take(assignment.creation, ~w(name owner_token incarnation))
      |> Map.merge(%{
        "target_id" => assignment.binding.target_id,
        "domain_generation" => assignment.binding.generation,
        "material_sha256" => String.duplicate("e", 64)
      })

    %Machine{
      name: record.machine_name,
      state: :running,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: profile.storage_gb,
      overlay_gb: profile.overlay_gb,
      backend_identity: %Identity{receipt: receipt, pid_identity: [100, 12_345]}
    }
  end

  def pending(adapter, store, id) do
    record = Contract.record(id)
    assert {:ok, _, :inserted} = adapter.accept(store, record, 10)
    assert {:ok, claimed} = adapter.claim(store, Execution.key(record), "owner", 1100, 10_000)
    claimed
  end

  def reserve(adapter, store, record, assignment) do
    name = if assignment, do: assignment.creation["name"], else: "legacy-" <> record.id
    allocation = {"worker", name, Contract.capacity()}
    allocation = if assignment, do: Tuple.insert_at(allocation, 3, assignment), else: allocation
    adapter.reserve(store, Execution.key(record), Contract.guard(record), allocation, 1200)
  end
end
