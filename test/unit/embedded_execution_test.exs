defmodule SmolBox.EmbeddedExecutionTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.Binding
  alias SmolBox.Backend.Embedded
  alias SmolBox.Embedded.{Config, Port}
  alias SmolBox.Runtime.Config, as: RuntimeConfig
  alias SmolBox.Runtime.{Executor, Target}
  alias SmolBox.Runtime.Machines, as: RuntimeMachines
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Command,
    Error,
    Execution,
    ExecutionSpec,
    FaultStore,
    ManagedMachine,
    ManagedMachineSpec,
    TestArtifacts
  }

  setup do
    native = Package.create(backend: true)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: __MODULE__,
      namespace: "native",
      store: {Memory, store},
      mode: :ephemeral,
      fingerprint_key: String.duplicate("k", 32),
      artifact_store: {TestArtifacts, artifacts},
      workers: [],
      poll_ms: 20
    ]

    {:ok, config} = RuntimeConfig.new(options)
    target = Target.normalize(native)

    {:ok, command} = Command.new(["echo"], user: "65534")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "native",
        id: "command",
        profile: hd(native.profiles),
        artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture)),
        command: command
      )

    %{native: native, store: store, options: options, config: config, target: target, spec: spec}
  end

  test "native target approvals and allocation are checked without helper dispatch", context do
    assert :ok = Target.validate(context.target)
    assert Target.supports?(context.target, context.spec)

    assert {:ok, {id, "approved-vm", capacity, assignment}} =
             Target.allocation(context.target, context.spec, "approved-vm")

    assert id == context.native.id
    assert capacity == context.native.capacity
    assert assignment.binding == struct!(Binding, Config.domain_binding(context.native))
    assert byte_size(assignment.creation["owner_token"]) == 64
    assert byte_size(assignment.creation["incarnation"]) == 32
    assert {:ok, machine} = Target.machine_spec(context.target, context.spec, "approved-vm")
    assert machine.cpus == context.spec.profile.cpus
    assert machine.memory_mb == context.spec.profile.memory_mb

    {:ok, command} = Command.new(["echo"], stdin: "unsupported")
    unsupported = %{context.spec | command: command}
    refute Target.supports?(context.target, unsupported)

    assert {:error, %Error{category: :unsupported_capability}} =
             Target.allocation(context.target, unsupported, "approved-vm")

    assert {:error, %Error{category: :validation}} =
             Target.validate(%{context.target | capacity: %{context.target.capacity | slots: 2}})

    assert Package.received(context.native) == []
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
  end

  test "public native configuration checks store capabilities without launching a helper",
       context do
    for worker <- [context.native, context.target] do
      assert {:ok, %{workers: [target]}} =
               RuntimeConfig.new(Keyword.put(context.options, :workers, [worker]))

      assert target == context.target
    end

    assert Package.received(context.native) == []
    assert :undefined == :global.whereis_name({Port, node()})
  end

  test "an unavailable captured target cannot bind to a helper appearing later", context do
    captured = Target.pin(context.target)
    assert captured.connection.context.pinned
    assert captured.connection.context.server == nil
    config = activate(context)
    record = accept(context, config)
    config = %{config | workers: [captured]}
    assert {:ok, pending} = Executor.run(config, Execution.key(record), [context.native.id])
    assert pending.state == :accepted
    assert pending.backend_assignment == nil
    assert requests(context.native) == []
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
    assert Target.pin(captured) == captured
  end

  test "work already assigned to HTTP never probes an unresponsive native owner", context do
    observer = self()

    owner =
      spawn(fn ->
        receive do
          :stop ->
            :ok

          _message ->
            send(observer, :native_contact)
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> send(owner, :stop) end)
    {:ok, reference} = Embedded.reference(context.native, owner)
    native = %{context.target | connection: reference}
    http = %Target{kind: :http, id: "http"}
    config = %{context.config | workers: [native, http]}
    assert Target.pin_config(config, %{worker_id: "http"}, [native.id, http.id]) == config
    refute_receive :native_contact, 20
  end

  test "internal execution persists native identity and releases only after observed absence",
       context do
    config = activate(context)
    record = accept(context, config)
    assert {:ok, completed} = Executor.run(config, Execution.key(record), [context.native.id])
    assert completed.state == :completed
    assert completed.evidence == :exited
    assert completed.result.exit_code == 7
    assert completed.result.stdout == <<"out", 0, 255>>
    assert completed.result.stderr == <<"err", 0, 254>>
    assert completed.cleanup == :complete
    assert is_integer(completed.absence_at_ms)
    assert completed.reservation == nil
    assert completed.created_machine.created_at == nil
    assert completed.backend_assignment.binding.target_id == context.native.id

    assert completed.created_machine.backend_identity.receipt["owner_token"] ==
             completed.backend_assignment.creation["owner_token"]

    assert {:ok, ^completed} = Memory.fetch(context.store, Execution.key(record))
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)

    assert {:ok, [^completed], nil} =
             Memory.backend_assignments(context.store, context.native.id, nil, 1)

    operations = requests(context.native)

    assert Enum.map(operations, & &1["operation"]["operation"]) ==
             ~w(qualify_creation create start inspect exec inspect stop inspect delete inspect)

    create = Enum.at(operations, 1)["operation"]["create"]
    assert create == completed.backend_assignment.creation

    for request <- Enum.drop(operations, 2) do
      assert request["operation"]["receipt"] == completed.created_machine.backend_identity.receipt
    end
  end

  @tag :deferred_crash
  test "owner loss keeps unknown evidence and reservation without replay", context do
    config = activate(context)
    {:ok, command} = Command.new(["hold"], timeout_secs: 10)
    record = accept(%{context | spec: %{context.spec | command: command}}, config)
    task = Task.async(fn -> Executor.run(config, Execution.key(record), [context.native.id]) end)
    await_exec(context.native)
    owner = :global.whereis_name({Port, node()})
    Process.unlink(owner)
    Process.exit(owner, :kill)
    assert {:ok, unknown} = Task.await(task, 3000)
    assert unknown.state == :unknown
    assert unknown.result == nil
    assert unknown.last_error.operation == :inspect
    assert unknown.reservation != nil
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert {:ok, again} = Executor.run(config, Execution.key(record), [context.native.id])
    assert again.state == :unknown
    assert Enum.count(requests(context.native), &(&1["operation"]["operation"] == "exec")) == 1
  end

  test "artifact qualification failure produces no reservation or native create", context do
    path = Path.join(context.native.package_path, "fixture.json")
    metadata = path |> File.read!() |> Jason.decode!() |> Map.put("reject_qualification", true)
    File.write!(path, Jason.encode!(metadata))
    config = activate(context)
    record = accept(context, config)
    assert {:ok, rejected} = Executor.run(config, Execution.key(record), [context.native.id])
    assert rejected.state == :failed
    assert rejected.evidence == :not_dispatched
    assert rejected.cleanup == :complete
    assert rejected.last_error.category == :unsupported_capability
    assert rejected.last_error.operation == :prepare_artifact
    assert rejected.backend_assignment == nil
    assert rejected.reservation == nil
    assert rejected.machine_name == nil
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)

    assert Enum.map(requests(context.native), & &1["operation"]["operation"]) == [
             "qualify_creation"
           ]

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native",
        id: "invalid",
        profile: context.spec.profile,
        artifact: context.spec.artifact
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, config.fingerprint_key)
    {:ok, machine} = ManagedMachine.new(spec, fingerprint, config.clock.now())
    {:ok, _} = Memory.machine(context.store, :accept, [machine, 10])

    assert {:ok, rejected_machine} =
             RuntimeMachines.run(config, ManagedMachine.key(machine), [context.native.id])

    assert rejected_machine.state == :conflict
    assert rejected_machine.reservation == nil
    assert rejected_machine.backend_assignment == nil
    assert rejected_machine.last_error.category == :unsupported_capability
    assert {:ok, encoded} = Codec.encode(rejected_machine)
    assert {:ok, ^rejected_machine} = Codec.decode(encoded)

    for evidence <- [:unknown, :dispatched] do
      assert {:error, %Error{category: :validation}} =
               ManagedMachine.validate(%{
                 rejected_machine
                 | last_error: %{rejected_machine.last_error | evidence: evidence}
               })
    end

    assert Enum.all?(
             requests(context.native),
             &(&1["operation"]["operation"] == "qualify_creation")
           )
  end

  test "named and sentinel users fail admission without invalidating historical record shape",
       context do
    for user <- ["nobody", "65534:nogroup", "4294967295", "1:4294967295", "+1"] do
      {:ok, command} = Command.new(["echo"], user: user)
      spec = %{context.spec | command: command}
      refute Target.supports?(context.target, spec)

      assert {:error, %Error{category: :unsupported_capability}} =
               Target.allocation(context.target, spec, "vm")
    end

    assert requests(context.native) == []
    config = activate(context)
    record = accept(context, config)
    assert {:ok, completed} = Executor.run(config, Execution.key(record), [context.native.id])
    {:ok, command} = Command.new(["echo"], user: "nobody")
    historical_spec = %{completed.spec | command: command}
    {:ok, fingerprint} = ExecutionSpec.fingerprint(historical_spec, config.fingerprint_key)
    historical = %{completed | spec: historical_spec, fingerprint: fingerprint}
    assert {:ok, bytes} = Codec.encode(historical)
    assert {:ok, ^historical} = Codec.decode(bytes)
    refute Target.supports?(context.target, historical.spec)
  end

  for replacement <- [:owner, :helper] do
    @replacement replacement
    @tag :deferred_crash
    test "delayed dispatch intent cannot cross a restarted #{@replacement}", context do
      config = activate(context)
      observer = self()

      gate =
        start_supervised!(
          {Agent,
           fn ->
             %{event: :dispatch_intent, phase: :after, fired: false, observer: observer}
           end},
          id: :intent_gate
        )

      config = %{config | store: {FaultStore, %{store: context.store, faults: gate}}}
      record = accept(context, config)

      task =
        Task.async(fn -> Executor.run(config, Execution.key(record), [context.native.id]) end)

      assert_receive {:boundary, :dispatch_intent, :after, blocked}, 3000
      assert {:ok, intent} = Memory.fetch(context.store, Execution.key(record))
      assert intent.state == :dispatching
      assert intent.backend_assignment != nil
      old_owner = :global.whereis_name({Port, node()})
      {:ok, %{epoch: old_epoch}} = Port.health(old_owner)

      fresh_owner =
        case @replacement do
          :owner ->
            stop_supervised!(Port)
            start_supervised!(Supervisor.child_spec({Port, context.native}, restart: :temporary))

          :helper ->
            request = Package.command(context.native, "crash")

            assert {:ok, handle} =
                     Port.submit(old_owner, request, context.native.budget, self(), old_epoch)

            assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
            assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, _}}, 1000
            assert_receive {:smolbox_embedded, ^handle, {:output, :stderr, _}}, 1000
            assert_receive {:smolbox_embedded, ^handle, {:channel_lost, %Error{}}}, 1000
            :ok = Port.acknowledge(old_owner, handle, 10)
            old_owner
        end

      await_reconciling(fresh_owner)
      {:ok, %{epoch: fresh_epoch}} = Port.health(fresh_owner)
      refute fresh_epoch == old_epoch
      :ok = Port.activate(fresh_owner, Config.domain_binding(context.native), fresh_epoch)
      request_count = length(requests(context.native))
      send(blocked, :release_boundary)
      assert {:ok, unknown} = Task.await(task, 3000)
      assert unknown.state == :unknown
      assert unknown.result == nil
      assert unknown.reservation != nil
      assert unknown.backend_assignment == intent.backend_assignment
      assert length(requests(context.native)) == request_count
      assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)

      expected_execs = if @replacement == :owner, do: 0, else: 1

      assert Enum.count(requests(context.native), &(&1["operation"]["operation"] == "exec")) ==
               expected_execs
    end
  end

  @tag :deferred_crash
  test "retained lifecycle intent stays uncertain when its owner is replaced before dispatch",
       context do
    config = activate(context)
    stopped = retain(context, config)
    key = ManagedMachine.key(stopped)

    {:ok, _} =
      Memory.machine(context.store, :request, [key, :start, stopped.version, config.clock.now()])

    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :machine_write, phase: :after, fired: false, observer: observer}
         end},
        id: :lifecycle_gate
      )

    config = %{config | store: {FaultStore, %{store: context.store, faults: gate}}}
    task = Task.async(fn -> RuntimeMachines.run(config, key, [context.native.id]) end)
    assert_receive {:boundary, :machine_write, :after, blocked}, 3000
    {:ok, intent} = Memory.machine(context.store, :fetch, [key])
    assert intent.phase == :dispatching
    assert intent.operation == :start
    stop_supervised!(Port)
    fresh = start_supervised!(Supervisor.child_spec({Port, context.native}, restart: :temporary))
    await_reconciling(fresh)
    {:ok, %{epoch: epoch}} = Port.health(fresh)
    :ok = Port.activate(fresh, Config.domain_binding(context.native), epoch)
    count = length(requests(context.native))
    send(blocked, :release_boundary)
    assert {:ok, unknown} = Task.await(task, 3000)
    assert unknown.state == :unknown
    assert unknown.phase == :uncertain
    assert unknown.operation == :start
    assert unknown.backend_assignment == intent.backend_assignment
    assert unknown.created_machine == stopped.created_machine
    assert unknown.reservation != nil
    assert length(requests(context.native)) == count
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "retained machine commands inherit ownership without a second capacity reservation",
       context do
    config = activate(context)
    created = retain(context, config)
    key = ManagedMachine.key(created)
    assert created.state == :stopped
    assert created.observed_machine.state == :stopped

    assert Enum.map(requests(context.native), & &1["operation"]["operation"]) ==
             ~w(qualify_creation create inspect)

    {:ok, _} =
      Memory.machine(context.store, :request, [key, :start, created.version, config.clock.now()])

    assert {:ok, running} = RuntimeMachines.run(config, key, [context.native.id])
    assert running.state == :running
    {:ok, fingerprint} = ExecutionSpec.fingerprint(context.spec, config.fingerprint_key)
    {:ok, execution} = Execution.new(context.spec, fingerprint, config.clock.now())

    assert {:ok, attached} =
             Memory.machine(context.store, :submit, [key, execution, 10, config.clock.now()])

    assert attached.backend_assignment == running.backend_assignment
    assert {:ok, completed} = Executor.run(config, Execution.key(attached), [context.native.id])
    assert completed.state == :completed
    assert completed.result.exit_code == 7
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert {:ok, idle} = Memory.machine(context.store, :fetch, [key])
    assert idle.active_execution == nil
    assert idle.reservation != nil
    assert idle.backend_assignment == running.backend_assignment
    assert Enum.count(requests(context.native), &(&1["operation"]["operation"] == "create")) == 1

    {:ok, _} =
      Memory.machine(context.store, :request, [key, :stop, idle.version, config.clock.now()])

    assert {:ok, stopped} = RuntimeMachines.run(config, key, [context.native.id])
    assert stopped.state == :stopped

    {:ok, _} =
      Memory.machine(context.store, :request, [key, :delete, stopped.version, config.clock.now()])

    assert {:ok, deleted} = RuntimeMachines.run(config, key, [context.native.id])
    assert deleted.state == :deleted
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
  end

  # Exercise the internal dispatcher while the public runtime constructor is gated.
  # This OS-Port peer is synthetic; it does not qualify the SDK or restart recovery.
  defp activate(context) do
    owner = start_supervised!(Supervisor.child_spec({Port, context.native}, restart: :temporary))
    await_reconciling(owner)
    :ok = Port.activate(owner, Config.domain_binding(context.native))

    {:ok, _} =
      Memory.bind_backend(
        context.store,
        context.native.id,
        struct!(Binding, Config.domain_binding(context.native))
      )

    config = %{context.config | workers: [context.target]}

    {:ok, _} =
      Memory.claim_worker(
        context.store,
        context.native.id,
        config.owner,
        config.clock.now(),
        config.lease_ms
      )

    config
  end

  defp accept(context, config) do
    {:ok, fingerprint} = ExecutionSpec.fingerprint(context.spec, config.fingerprint_key)
    {:ok, record} = Execution.new(context.spec, fingerprint, config.clock.now())
    {:ok, _, :inserted} = Memory.accept(context.store, record, config.max_pending)
    record
  end

  defp retain(context, config) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native",
        id: "retained",
        profile: context.spec.profile,
        artifact: context.spec.artifact
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, config.fingerprint_key)
    {:ok, initial} = ManagedMachine.new(spec, fingerprint, config.clock.now())
    {:ok, _} = Memory.machine(context.store, :accept, [initial, 10])
    {:ok, created} = RuntimeMachines.run(config, ManagedMachine.key(initial), [context.native.id])
    created
  end

  defp requests(native), do: Enum.filter(Package.received(native), &(&1["type"] == "request"))

  defp await_reconciling(owner, remaining \\ 200) do
    case Port.health(owner) do
      {:ok, %{status: :reconciling}} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(10)
        await_reconciling(owner, remaining - 1)

      _ ->
        flunk("helper did not reach reconciliation")
    end
  end

  defp await_exec(native, remaining \\ 200) do
    if Enum.any?(requests(native), &(&1["operation"]["operation"] == "exec")) do
      :ok
    else
      assert remaining > 0, "execution request was not observed"
      Process.sleep(10)
      await_exec(native, remaining - 1)
    end
  end
end
