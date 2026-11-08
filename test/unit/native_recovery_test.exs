defmodule SmolBox.NativeRecoveryTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.{Config, Identity, Port}
  alias SmolBox.Runtime.Config, as: RuntimeConfig
  alias SmolBox.Runtime.{NativeAuthority, NativeSupervisor, NativeSupport, Target, WorkerConfig}
  alias SmolBox.Store.{Contract, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Client,
    Command,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Runtime,
    TestArtifacts,
    Worker
  }

  defmodule OldStore do
    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :backend_recovery)}
    end
  end

  defmodule FaultStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :backend_assignments do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)({store, _fault}, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def backend_assignments({store, fault}, worker, cursor, limit) do
      mode = Agent.get_and_update(fault, fn {mode, count} -> {mode, {mode, count + 1}} end)

      case mode do
        :error -> {:error, %SmolBox.Error{category: :store, operation: :backend_assignments}}
        :malformed -> {:ok, [], :invalid}
        :repeated -> {:ok, [], {0, "a", "a"}}
        :normal -> Memory.backend_assignments(store, worker, cursor, limit)
      end
    end
  end

  setup do
    native = Package.create(backend: true, persistent_backend: true)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{{"contract", "input"} => <<0, 255>>} end})

    {:ok, config} =
      RuntimeConfig.new(
        name: __MODULE__,
        namespace: "recover",
        mode: :ephemeral,
        store: {Memory, store},
        artifact_store: {TestArtifacts, artifacts},
        fingerprint_key: String.duplicate("k", 32),
        workers: [],
        poll_ms: 20
      )

    config = %{config | workers: [Target.normalize(native)]}
    %{native: native, store: store, config: config}
  end

  test "enrollment fails before any helper launch when recovery capability is missing", context do
    config = %{context.config | store: {OldStore, context.store}}
    assert {:error, %{category: :unsupported_capability}} = NativeSupport.verify(config)
    assert {:error, %{category: :unsupported_capability}} = NativeSupervisor.start_link(config)
    assert Package.received(context.native) == []
    assert :global.whereis_name({Port, node()}) == :undefined
  end

  test "an empty authority activates only its enrolled fresh helper", context do
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)

    assert {:ok, binding} =
             Memory.bind_backend(
               context.store,
               context.native.id,
               struct!(Binding, Config.domain_binding(context.native))
             )

    assert binding.generation == context.native.domain_generation
    assert operations(context.native) == []
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
    state = :sys.get_state(Runtime.coordinator(runtime))
    assert get_in(state.health, [context.native.id, :recovery, :phase]) == :ready
  end

  test "store errors and malformed or repeated cursors cannot authorize native admission",
       context do
    for mode <- [:error, :malformed, :repeated] do
      fault =
        start_supervised!(Supervisor.child_spec({Agent, fn -> {mode, 0} end}, id: FaultStore))

      config = %{context.config | store: {FaultStore, {context.store, fault}}}
      runtime = start_runtime(config)
      await(fn -> Agent.get(fault, fn {_mode, count} -> count >= 3 end) end)
      assert {:ok, [%{status: :unavailable}]} = SmolBox.workers(runtime)
      owner = :global.whereis_name({Port, node()})
      assert {:ok, %{status: :reconciling}} = Port.health(owner)
      assert operations(context.native) == []
      Agent.update(fault, fn {_mode, count} -> {:normal, count} end)
      await(fn -> ready?(runtime) end)
      stop_supervised!(Runtime)
      stop_supervised!(FaultStore)
    end
  end

  test "startup observes retained storage without booting or releasing its reservation",
       context do
    seed = seed_machine(context, :receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    assert {:ok, saved} = Memory.machine(context.store, :fetch, [ManagedMachine.key(seed)])
    assert saved.state == :stopped
    assert saved.backend_assignment == seed.backend_assignment
    assert saved.created_machine == seed.created_machine
    assert saved.reservation == seed.reservation
    assert operations(context.native) != []
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "startup preserves a native export intent as unknown without publication or cleanup replay",
       context do
    native = Package.create(backend: true, persistent_backend: true, protocol_major: 2)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    native = %{native | capacity: %{slots: 16, cpus: 64, memory_mb: 131_072, disk_gb: 1024}}
    config = %{context.config | workers: [Target.normalize(native)]}
    seed = seed_machine(%{context | native: native, config: config}, :receipt)
    key = ManagedMachine.key(seed)
    spec = SmolBox.Store.ExportContract.spec("export-recovery", "export-recovery")
    {:ok, fingerprint} = SmolBox.ExportSpec.fingerprint(spec, key, config.fingerprint_key)

    [approval] =
      SmolBox.Embedded.ExportContract.approvals(%{export_destinations: [spec.destination]})

    request = %{
      "request_sha256" => fingerprint,
      "destination_id" => spec.destination.id,
      "destination_sha256" => approval["destination_sha256"],
      "tag" => spec.tag,
      "max_artifact_bytes" => 8_589_934_592,
      "max_staging_bytes" => 137_438_953_472
    }

    assert {:ok, accepted} =
             Memory.machine(context.store, :export_accept, [
               key,
               spec,
               fingerprint,
               native.capacity,
               config.clock.now()
             ])

    assert {:ok, sent} =
             Memory.machine(context.store, :export_advance, [
               key,
               Contract.guard(accepted),
               spec.id,
               :accepted,
               [state: :dispatching, native_request: request],
               config.clock.now()
             ])

    runtime = start_runtime(config)
    await(fn -> ready?(runtime) end)
    assert {:ok, saved} = Memory.machine(context.store, :fetch, [key])
    assert saved.exports[spec.id].state == :unknown and saved.active_export == spec.id
    assert saved.exports[spec.id].native_authority == sent.exports[spec.id].native_authority
    assert saved.exports[spec.id].receipt == nil and saved.exports[spec.id].result == nil
    assert saved.created_machine == sent.created_machine and saved.reservation == sent.reservation
    assert {:ok, %{slots: 2, disk_gb: 130}} = Memory.usage(context.store, native.id)
    assert Enum.all?(operations(native), &(&1 == "inspect"))
  end

  test "a lost creation receipt remains unverified and keeps its reservation", context do
    seed = seed_machine(context, :no_receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    assert {:ok, saved} = Memory.machine(context.store, :fetch, [ManagedMachine.key(seed)])
    assert saved.state == :unknown
    assert saved.phase == :uncertain
    assert saved.operation == :create
    assert saved.created_machine == nil
    assert saved.backend_assignment == seed.backend_assignment
    assert operations(context.native) == []
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "an unknown retained command blocks its slot after owner restart without replay",
       context do
    {seed, attached, preparing} = seed_unknown_command(context)
    key = ManagedMachine.key(seed)

    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    assert {:ok, unknown} = Memory.fetch(context.store, Execution.key(attached))
    assert unknown.state == :unknown
    assert unknown.result == nil
    assert unknown.backend_assignment == preparing.backend_assignment
    assert {:ok, blocked} = Memory.machine(context.store, :fetch, [key])
    assert blocked.active_execution == Execution.key(attached)
    assert blocked.state == :unknown
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "missing retained storage remains missing and reserved", context do
    seed = seed_machine(context, :receipt)
    File.rm!(Path.join(context.native.package_path, "vm.json"))
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    assert {:ok, saved} = Memory.machine(context.store, :fetch, [ManagedMachine.key(seed)])
    assert saved.state == :missing
    assert saved.created_machine == seed.created_machine
    assert saved.reservation == seed.reservation
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  @tag :deferred_crash
  test "coordinator restart reconciles the existing owner without booting retained storage",
       context do
    seed = seed_machine(context, :receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    owner = :global.whereis_name({Port, node()})
    before = Runtime.coordinator(runtime)
    Process.exit(before, :kill)
    await(fn -> Runtime.coordinator(runtime) != before and ready?(runtime) end)
    assert :global.whereis_name({Port, node()}) == owner
    assert {:ok, saved} = Memory.machine(context.store, :fetch, [ManagedMachine.key(seed)])
    assert saved.state == :stopped
    assert saved.reservation == seed.reservation
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
  end

  test "native worker reports separate declared accounting and unsupported measurements",
       context do
    seed = seed_machine(context, :receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    assert {:ok, [worker]} = SmolBox.workers(runtime)
    assert worker.health.backend_kind == :embedded
    assert worker.health.bridge == :port
    assert worker.health.protocol_version == %{major: 1, minor: 3}
    assert worker.health.lifetime == :owner_bound
    assert worker.health.package_preflight == :passed
    assert worker.health.engine_limits["memory_mib_max"] == 65_536
    assert worker.health.bridge_limits.in_flight == context.native.limits.in_flight
    refute Map.has_key?(worker.health, :epoch)
    assert {:ok, report} = SmolBox.worker_report(runtime, context.native.id)
    assert report.reserved.slots == 1
    assert report.observed_capacity == nil
    assert report.capacity_error.category == :unsupported_capability
    assert {:ok, [admission]} = SmolBox.admission_report(runtime, seed.spec)
    assert {:capacity, :slots} in admission.blockers
    assert {:ok, saved} = SmolBox.Machines.inspect(runtime, ManagedMachine.key(seed))
    assert saved.reservation == seed.reservation
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
  end

  test "optional native APIs and unsupported retained commands fail before mutations", context do
    seed = seed_machine(context, :receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    key = ManagedMachine.key(seed)

    assert :ok =
             NativeAuthority.run(Runtime.coordinator(runtime), context.native.id, fn ->
               assert {:ok, before} = SmolBox.Machines.inspect(runtime, key)
               requests = operations(context.native)

               for call <- [
                     fn -> SmolBox.Machines.logs(runtime, key) end,
                     fn -> SmolBox.Machines.measurements(runtime, key) end,
                     fn -> SmolBox.Machines.list_images(runtime, key) end,
                     fn ->
                       SmolBox.Machines.expand_disks(runtime, key, "grow", before.version,
                         storage_gb: 2
                       )
                     end,
                     fn ->
                       SmolBox.Machines.resolve_disk_expansion(
                         runtime,
                         key,
                         "grow",
                         before.version,
                         quiesced: true
                       )
                     end
                   ] do
                 assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
                          call.()
               end

               for options <- [[stdin: "unsupported"], [background: true]] do
                 {:ok, command} = Command.new(["echo"], options)

                 {:ok, spec} =
                   ExecutionSpec.new(
                     scope: seed.scope,
                     id: "unsupported",
                     profile: seed.spec.profile,
                     artifact: seed.spec.artifact,
                     command: command
                   )

                 assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
                          SmolBox.Machines.submit(runtime, key, spec)

                 assert {:error, %{category: :not_found}} =
                          Memory.fetch(context.store, Execution.key(spec))
               end

               assert {:ok, ^before} = SmolBox.Machines.inspect(runtime, key)
               assert operations(context.native) == requests
               :ok
             end)

    await(fn -> ready?(runtime) end)
  end

  test "native audit pages authority records without writes or shared SDK enumeration", context do
    seed = seed_machine(context, :receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)

    assert :ok =
             NativeAuthority.run(Runtime.coordinator(runtime), context.native.id, fn ->
               assert {:ok, before} = SmolBox.Machines.inspect(runtime, ManagedMachine.key(seed))
               assert {:ok, _, :inserted} = Memory.accept(context.store, Contract.record(), 10)
               requests = operations(context.native)
               assert {:ok, empty} = SmolBox.audit_worker(runtime, context.native.id, limit: 100)
               assert empty.candidates == []
               assert is_tuple(empty.next_cursor)
               assert empty.foreign_count == nil
               assert empty.inventory_scope == :assigned_records

               assert {:ok, page} =
                        SmolBox.audit_worker(runtime, context.native.id,
                          cursor: empty.next_cursor
                        )

               assert page.next_cursor == nil

               assert [%{status: :owned, observed_state: :stopped, managed_machine: key}] =
                        page.candidates

               assert key == ManagedMachine.key(seed)
               refute inspect(page) =~ seed.backend_assignment.creation["owner_token"]
               refute inspect(page) =~ context.native.package_path
               assert {:ok, ^before} = SmolBox.Machines.inspect(runtime, key)
               assert length(operations(context.native)) == length(requests) + 1
               assert List.last(operations(context.native)) == "inspect"

               assert {:error, %{category: :validation}} =
                        SmolBox.audit_worker(runtime, context.native.id, cursor: "name")

               :ok
             end)

    await(fn -> ready?(runtime) end)
  end

  test "receipt-less resolution refuses present material without adopting labels", context do
    seed = seed_machine(context, :no_receipt)

    File.write!(
      Path.join(context.native.package_path, "vm.json"),
      Jason.encode!(%{
        "resources" => seed.backend_assignment.creation["resources"],
        "state" => "stopped"
      })
    )

    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    key = ManagedMachine.key(seed)

    assert {:ok, %{candidates: [%{status: :unverified}]}} =
             SmolBox.audit_worker(runtime, context.native.id)

    assert operations(context.native) == []

    assert {:error, %{category: :unsupported_capability}} =
             resolve_current(runtime, key, :stopped)

    assert {:error, %{category: :identity_conflict}} = resolve_current(runtime, key, :deleted)
    assert {:ok, current} = SmolBox.Machines.inspect(runtime, key)
    assert current.created_machine == nil
    assert current.backend_assignment == seed.backend_assignment
    assert current.reservation == seed.reservation
    assert current.state == :unknown
    assert operations(context.native) == ["inspect_creation"]
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "only explicit quiesced intent absence resolves a lost receipt and releases capacity",
       context do
    seed = seed_machine(context, :no_receipt)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    key = ManagedMachine.key(seed)
    assert operations(context.native) == []
    assert {:ok, before} = SmolBox.Machines.inspect(runtime, key)

    assert {:error, %{category: :validation}} =
             SmolBox.Machines.resolve(runtime, key, before.version, disposition: :deleted)

    assert operations(context.native) == []
    assert {:ok, resolved} = resolve_current(runtime, key, :deleted)
    assert resolved.state == :deleted
    assert resolved.created_machine == nil
    assert resolved.reservation == nil
    assert resolved.backend_assignment == seed.backend_assignment
    assert is_integer(resolved.absence_at_ms)
    assert operations(context.native) == ["inspect_creation"]
    query = Package.received(context.native) |> Enum.find(&(&1["type"] == "request"))
    assert query["operation"]["create"] == seed.backend_assignment.creation
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
  end

  test "explicit native stopped resolution unblocks the slot while preserving unknown result",
       context do
    {seed, attached, _preparing} = seed_unknown_command(context)
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    key = ManagedMachine.key(seed)
    assert {:ok, resolved} = resolve_current(runtime, key, :stopped)
    assert resolved.state == :stopped
    assert resolved.active_execution == nil
    assert resolved.reservation == seed.reservation
    assert resolved.created_machine == seed.created_machine
    assert {:ok, unknown} = Memory.fetch(context.store, Execution.key(attached))
    assert unknown.state == :unknown
    assert unknown.result == nil
    assert unknown.cleanup == :complete

    await(fn -> ready?(runtime) end)
    assert {:ok, ^unknown} = Memory.fetch(context.store, Execution.key(attached))

    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "explicit native deleted resolution releases only receipt-bound observed absence",
       context do
    seed = seed_machine(context, :receipt)
    File.rm!(Path.join(context.native.package_path, "vm.json"))
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    key = ManagedMachine.key(seed)

    assert {:ok, %{candidates: [%{status: :absent, observed_state: :missing}]}} =
             SmolBox.audit_worker(runtime, context.native.id)

    assert {:ok, resolved} = resolve_current(runtime, key, :deleted)
    assert resolved.state == :deleted
    assert resolved.reservation == nil
    assert is_integer(resolved.absence_at_ms)
    assert resolved.created_machine == seed.created_machine
    await(fn -> ready?(runtime) end)
    assert Enum.all?(operations(context.native), &(&1 == "inspect"))
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
  end

  @tag :deferred_crash
  test "dead authority holders stay frozen until successful reconciliation", context do
    fault = start_supervised!({Agent, fn -> {:normal, 0} end}, id: FaultStore)
    config = %{context.config | store: {FaultStore, {context.store, fault}}}
    runtime = start_runtime(config)
    await(fn -> ready?(runtime) and native_idle?(runtime) end)
    coordinator = Runtime.coordinator(runtime)
    parent = self()

    holder =
      spawn(fn ->
        NativeAuthority.run(coordinator, context.native.id, fn ->
          owner = :global.whereis_name({Port, node()})
          {:ok, %{epoch: epoch}} = Port.health(owner)
          :ok = Port.quiesce(owner, epoch)
          send(parent, :holding_native_authority)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :holding_native_authority, 1000

    assert {:ok, [%{status: :unavailable, health_status: :unavailable}]} =
             SmolBox.workers(runtime)

    assert {:error, %{category: :admission_exhausted}} =
             NativeAuthority.run(coordinator, context.native.id, fn ->
               flunk("overlapping authority")
             end)

    assert {:error, %{category: :stale_claim}} =
             GenServer.call(coordinator, {:native_ready, context.native.id})

    Agent.update(fault, fn {_mode, count} -> {:error, count} end)
    Process.exit(holder, :kill)
    await(fn -> :sys.get_state(coordinator).native_holders == %{} end)
    assert {:ok, [%{status: :unavailable}]} = SmolBox.workers(runtime)
    assert {:ok, %{status: :reconciling}} = Port.health(:global.whereis_name({Port, node()}))
    Agent.update(fault, fn {_mode, count} -> {:normal, count} end)
    await(fn -> ready?(runtime) end)
    assert operations(context.native) == []
  end

  test "VM-mode guest users are rejected before retained slot attachment", context do
    seed = seed_machine(context, :receipt)
    path = Path.join(context.native.package_path, "fixture.json")
    metadata = path |> File.read!() |> Jason.decode!() |> Map.put("vm_artifact", true)
    File.write!(path, Jason.encode!(metadata))
    runtime = start_runtime(context.config)
    await(fn -> ready?(runtime) end)
    {:ok, current} = SmolBox.Machines.inspect(runtime, ManagedMachine.key(seed))
    {:ok, command} = Command.new(["echo"], user: "65534:65534")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: seed.scope,
        id: "vm-user",
        profile: seed.spec.profile,
        artifact: seed.spec.artifact,
        command: command
      )

    assert {:error,
            %{
              category: :unsupported_capability,
              operation: :qualify_creation,
              evidence: :not_dispatched
            }} = SmolBox.Machines.submit(runtime, ManagedMachine.key(seed), spec)

    assert {:ok, %{active_execution: nil, reservation: reservation}} =
             SmolBox.Machines.inspect(runtime, ManagedMachine.key(seed))

    assert reservation == current.reservation

    assert {:error, %{category: :not_found}} =
             Memory.fetch(context.store, {spec.scope, spec.id})

    refute "exec" in operations(context.native)
  end

  @tag :deferred_crash
  test "helper loss recovers its target while HTTP continues serving", context do
    {_peer, port} = SmolBox.ManagedPeer.start()
    spec = Contract.record().spec

    {:ok, endpoint} =
      Worker.new("http-peer", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)

    {:ok, http} =
      WorkerConfig.new(
        client: client,
        platform: :linux,
        architecture: "x86_64",
        profiles: [spec.profile],
        artifacts: [Map.put(spec.artifact, "path", "/approved/python.smolmachine")],
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
        capacity: Contract.capacity(1)
      )

    config = %{context.config | workers: context.config.workers ++ [Target.normalize(http)]}
    runtime = start_runtime(config)

    await(fn ->
      match?({:ok, [%{status: :ready}, %{status: :ready}]}, SmolBox.workers(runtime))
    end)

    coordinator = Runtime.coordinator(runtime)
    owner = :global.whereis_name({Port, node()})
    {:ok, %{epoch: epoch}} = Port.health(owner)

    {:ok, handle} =
      Port.submit(
        owner,
        Package.command(context.native, "crash"),
        context.native.budget,
        self(),
        epoch
      )

    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, _}}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stderr, _}}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:channel_lost, _}}, 1000
    :ok = Port.acknowledge(owner, handle, 10)
    assert {:ok, execution} = SmolBox.submit(runtime, spec)
    assert {:ok, completed} = SmolBox.await(runtime, execution, 5000)
    assert completed.state == :completed
    assert completed.worker_id == "http-peer"
    assert Runtime.coordinator(runtime) == coordinator

    await(fn ->
      match?({:ok, [%{status: :ready}, %{status: :ready}]}, SmolBox.workers(runtime))
    end)

    {:ok, %{epoch: fresh}} = Port.health(owner)
    refute fresh == epoch
    assert Enum.count(operations(context.native), &(&1 == "exec")) == 1

    {NativeSupervisor, native_supervisor, :supervisor, _} =
      Enum.find(Supervisor.which_children(runtime), &(elem(&1, 0) == NativeSupervisor))

    [{_target, target_supervisor, :supervisor, _}] =
      Supervisor.which_children(native_supervisor)

    monitor = Process.monitor(target_supervisor)

    for _ <- 1..3 do
      previous = :global.whereis_name({Port, node()})
      Process.exit(previous, :kill)

      await(fn ->
        current = :global.whereis_name({Port, node()})

        is_pid(current) and current != previous and
          match?({:ok, [%{status: :ready}, %{status: :ready}]}, SmolBox.workers(runtime))
      end)
    end

    Process.exit(:global.whereis_name({Port, node()}), :kill)
    assert_receive {:DOWN, ^monitor, :process, ^target_supervisor, :shutdown}, 1000

    await(fn ->
      match?({:ok, [%{status: :unavailable}, %{status: :ready}]}, SmolBox.workers(runtime))
    end)

    assert Process.alive?(native_supervisor)
    assert Runtime.coordinator(runtime) == coordinator
    assert :global.whereis_name({Port, node()}) == :undefined
    assert {:ok, next} = SmolBox.submit(runtime, %{spec | id: "after-native-quarantine"})

    assert {:ok, %{state: :completed, worker_id: "http-peer"}} =
             SmolBox.await(runtime, next, 5000)
  end

  defp seed_unknown_command(context) do
    seed = seed_machine(context, :receipt)
    key = ManagedMachine.key(seed)

    running = %{
      seed.created_machine
      | state: :running,
        backend_identity: %{seed.created_machine.backend_identity | pid_identity: [4242, 123_456]}
    }

    {:ok, saved} =
      Memory.machine(context.store, :write, [
        key,
        Contract.guard(seed),
        [state: :running, observed_machine: running],
        context.config.clock.now()
      ])

    File.write!(
      Path.join(context.native.package_path, "vm.json"),
      Jason.encode!(%{
        "resources" => seed.backend_assignment.creation["resources"],
        "state" => "stopped"
      })
    )

    {:ok, command} = Command.new(["echo"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: saved.scope,
        id: "uncertain",
        profile: saved.spec.profile,
        artifact: saved.spec.artifact,
        command: command
      )

    {:ok, fp} = ExecutionSpec.fingerprint(spec, context.config.fingerprint_key)
    {:ok, initial} = Execution.new(spec, fp, context.config.clock.now())

    {:ok, attached} =
      Memory.machine(context.store, :submit, [key, initial, 10, context.config.clock.now()])

    {:ok, claimed} =
      Memory.claim(
        context.store,
        Execution.key(attached),
        context.config.owner,
        context.config.clock.now(),
        context.config.lease_ms
      )

    {:ok, preparing} =
      Memory.write(
        context.store,
        Execution.key(attached),
        Contract.guard(claimed),
        [state: :preparing],
        context.config.clock.now()
      )

    {seed, attached, preparing}
  end

  defp seed_machine(context, evidence) do
    config = context.config
    native = context.native

    {:ok, _} =
      Memory.bind_backend(
        context.store,
        native.id,
        struct!(Binding, Config.domain_binding(native))
      )

    {:ok, _} =
      Memory.claim_worker(
        context.store,
        native.id,
        config.owner,
        config.clock.now(),
        config.lease_ms
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "recovery",
        id: "retained",
        profile: hd(native.profiles),
        artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      )

    {:ok, fp} = ManagedMachineSpec.fingerprint(spec, config.fingerprint_key)
    {:ok, initial} = ManagedMachine.new(spec, fp, config.clock.now())
    key = ManagedMachine.key(initial)
    {:ok, _} = Memory.machine(context.store, :accept, [initial, 10])

    {:ok, claimed} =
      Memory.machine(context.store, :claim, [
        key,
        config.owner,
        config.clock.now(),
        config.lease_ms
      ])

    {:ok, intent} = Assignment.new(native, spec, "retained-native")

    {:ok, reserved} =
      Memory.machine(context.store, :reserve, [
        key,
        Contract.guard(claimed),
        {native.id, "retained-native", native.capacity, intent},
        config.clock.now()
      ])

    if evidence == :no_receipt do
      reserved
    else
      receipt =
        Map.take(intent.creation, ~w(name owner_token incarnation))
        |> Map.merge(%{
          "target_id" => native.id,
          "domain_generation" => native.domain_generation,
          "material_sha256" => String.duplicate("9", 64)
        })

      receipt =
        if Config.protocol_major(native) == 2,
          do: Map.put(receipt, "material", Package.receipt(native)["material"]),
          else: receipt

      receipt =
        if Config.protocol_major(native) == 2 do
          ordered = %Jason.OrderedObject{
            values:
              Enum.map(
                ~w(target_id domain_generation name owner_token incarnation material_sha256),
                &{&1, Map.fetch!(receipt, &1)}
              )
          }

          hash =
            ["smolbox-material-origin-v2", ordered]
            |> Jason.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          put_in(receipt, ["material", "chain_sha256"], hash)
        else
          receipt
        end

      profile = spec.profile

      machine = %Machine{
        name: reserved.machine_name,
        state: :stopped,
        created_at: nil,
        cpus: profile.cpus,
        memory_mb: profile.memory_mb,
        storage_gb: profile.storage_gb,
        overlay_gb: profile.overlay_gb,
        backend_identity: %Identity{receipt: receipt}
      }

      File.write!(
        Path.join(native.package_path, "vm.json"),
        Jason.encode!(%{
          "resources" => intent.creation["resources"],
          "state" => "stopped"
        })
      )

      {:ok, saved} =
        Memory.machine(context.store, :write, [
          key,
          Contract.guard(reserved),
          [
            state: :stopped,
            operation: nil,
            phase: nil,
            created_machine: machine,
            observed_machine: machine
          ],
          config.clock.now()
        ])

      saved
    end
  end

  # Public admission is still gated; test the actual supervised subtree using
  # already validated internal configuration. The peer never opens an SDK/VM.
  defp start_runtime(config),
    do:
      start_supervised!(%{
        id: Runtime,
        start: {Supervisor, :start_link, [Runtime, config, [name: config.name]]},
        type: :supervisor
      })

  defp ready?(runtime), do: match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime))

  defp native_idle?(runtime),
    do: :sys.get_state(Runtime.coordinator(runtime)).task_targets == %{}

  defp resolve_current(runtime, key, disposition, remaining \\ 100) do
    {:ok, current} = SmolBox.Machines.inspect(runtime, key)

    case SmolBox.Machines.resolve(runtime, key, current.version,
           quiesced: true,
           disposition: disposition
         ) do
      {:error, %{category: category}}
      when category in [:stale_version, :admission_exhausted] and remaining > 0 ->
        Process.sleep(10)
        resolve_current(runtime, key, disposition, remaining - 1)

      result ->
        result
    end
  end

  defp operations(native),
    do:
      Package.received(native)
      |> Enum.filter(&(&1["type"] == "request"))
      |> Enum.map(& &1["operation"]["operation"])

  defp await(predicate, remaining \\ 500) do
    cond do
      predicate.() ->
        :ok

      remaining > 0 ->
        Process.sleep(10)
        await(predicate, remaining - 1)

      true ->
        flunk("native runtime did not become ready")
    end
  end
end
