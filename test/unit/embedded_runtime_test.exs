defmodule SmolBox.EmbeddedRuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Command, ExecutionSpec, Machines, ManagedMachineSpec, TestArtifacts}
  alias SmolBox.Embedded.Port
  alias SmolBox.Runtime.Config
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule NoRecoveryStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :backend_recovery)}
    end
  end

  setup context do
    native =
      Package.create(
        backend: true,
        persistent_backend: true,
        protocol_major: context[:protocol_major] || 1,
        protocol_minor: context[:protocol_minor] || if(context[:unmodified], do: 4, else: 3),
        unreachable_after_start: context[:unreachable_after_start]
      )

    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: __MODULE__,
      namespace: "public",
      mode: :ephemeral,
      store: {Memory, store},
      artifact_store: {TestArtifacts, artifacts},
      fingerprint_key: String.duplicate("k", 32),
      workers: [native],
      poll_ms: 20
    ]

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "public",
        id: "retained",
        profile: hd(native.profiles),
        artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      )

    %{native: native, store: store, options: options, spec: spec}
  end

  @tag protocol_major: 2, protocol_minor: 0, unreachable_after_start: true
  test "a verified native start reply completes the lifecycle without a second agent probe",
       context do
    runtime = start_supervised!(SmolBox.child_spec(context.options))
    await(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end)
    assert {:ok, handle} = Machines.create(runtime, context.spec)
    assert {:ok, %{state: :stopped} = created} = Machines.await(runtime, handle, 5000)
    before = length(Package.received(context.native))

    assert {:ok, _} = lifecycle(runtime, handle, :start, created.version)

    assert {:ok, %{state: :running, operation: nil} = running} =
             Machines.await(runtime, handle, 5000)

    assert running.reservation == created.reservation
    assert running.created_machine == created.created_machine
    assert running.observed_machine.backend_identity.pid_identity == [4242, 123_456]

    lifecycle_requests =
      for %{"type" => "request", "operation" => %{"operation" => operation}} <-
            context.native |> Package.received() |> Enum.drop(before),
          operation in ["inspect", "start"],
          do: operation

    assert lifecycle_requests == ["inspect", "start"]
  end

  for {major, minor} <- [{1, 3}, {1, 4}, {2, 0}] do
    @tag protocol_major: major, protocol_minor: minor
    test "protocol #{major}.#{minor} public startup runs retained work while draining and resumes",
         context do
      runtime = start_supervised!(SmolBox.child_spec(context.options))
      await(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end)
      assert {:ok, handle} = Machines.create(runtime, context.spec)
      assert {:ok, %{state: :stopped} = created} = Machines.await(runtime, handle, 5000)
      assert created.backend_assignment != nil
      assert created.backend_assignment.version == context.protocol_major
      assert {:ok, encoded} = Codec.encode(created)
      assert {:ok, ^created} = Codec.decode(encoded)

      if context.protocol_major == 2 do
        assert String.starts_with?(encoded, "smolbox-record-v17\0")
        assert created.created_machine.backend_identity.receipt["material"]["revision"] == 0
      else
        assert String.starts_with?(encoded, "smolbox-record-v16\0")
        refute Map.has_key?(created.created_machine.backend_identity.receipt, "material")
      end

      assert :ok = SmolBox.drain_worker(runtime, context.native.id)

      assert {:ok, %{assessment: :blocked, reserved: %{slots: 1}}} =
               SmolBox.worker_maintenance(runtime, context.native.id)

      assert {:ok, _} = Machines.start(runtime, handle, created.version)
      assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 5000)
      {:ok, command} = Command.new(["echo"])

      {:ok, spec} =
        ExecutionSpec.new(
          scope: context.spec.scope,
          id: "existing-command",
          profile: context.spec.profile,
          artifact: context.spec.artifact,
          command: command
        )

      data = <<0, 255, 7>>
      artifacts = elem(context.options[:artifact_store], 1)
      Agent.update(artifacts, &Map.put(&1, {"public", "input"}, data))

      input = %{
        "source" => "input",
        "path" => "/workspace/in.bin",
        "size" => 3,
        "sha256" => SmolBox.Files.sha256(data),
        "mode" => "runtime_default"
      }

      output = %{"destination" => "collected", "path" => "/workspace/in.bin", "max_bytes" => 32}
      spec = %{spec | inputs: [input], outputs: [output]}
      assert {:ok, execution} = Machines.submit(runtime, handle, spec)

      assert {:ok, %{state: :completed, collection: :complete, result: %{exit_code: 7}}} =
               SmolBox.await(runtime, execution, 5000)

      assert Agent.get(artifacts, &Map.fetch!(&1, {execution, "collected"})) ==
               {data, SmolBox.Files.sha256(data)}

      # Command result availability precedes durable slot retirement. Wait for
      # retirement before taking the version used by the next lifecycle CAS.
      await(fn ->
        match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, handle)) and
          match?(
            {:ok, %{cleanup: :complete}},
            SmolBox.fetch(runtime, elem(execution, 0), elem(execution, 1))
          )
      end)

      assert {:ok, %{state: :running} = running} = Machines.await(runtime, handle, 5000)
      assert {:ok, _} = lifecycle(runtime, handle, :stop, running.version)
      assert {:ok, %{state: :stopped} = stopped} = Machines.await(runtime, handle, 5000)
      assert {:ok, _} = lifecycle(runtime, handle, :delete, stopped.version)
      assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)

      assert {:ok, queued} = SmolBox.submit(runtime, %{spec | id: "drained", queue_ms: 100})
      assert {:ok, %{state: :expired, worker_id: nil}} = SmolBox.await(runtime, queued, 5000)
      assert {:ok, report} = SmolBox.worker_maintenance(runtime, context.native.id)
      assert report.records == [] and report.reserved.slots == 0

      assert {:ok, %{mode: :active}} =
               SmolBox.resume_worker(runtime, context.native.id, report.control.version)

      assert {:ok, next} = SmolBox.submit(runtime, %{spec | id: "resumed"})
      assert {:ok, %{state: :completed}} = SmolBox.await(runtime, next, 5000)

      await(fn ->
        match?(
          {:ok, %{cleanup: :complete, reservation: nil}},
          SmolBox.fetch(runtime, elem(next, 0), elem(next, 1))
        )
      end)

      assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
    end
  end

  test "missing recovery capability and multiple native domains reject before helper launch",
       context do
    assert {:error, %{category: :unsupported_capability}} =
             Config.new(Keyword.put(context.options, :store, {NoRecoveryStore, context.store}))

    second = %{context.native | id: "another-domain"}

    assert {:error, %{category: :unsupported_capability}} =
             Config.new(Keyword.put(context.options, :workers, [context.native, second]))

    assert Package.received(context.native) == []
    assert :global.whereis_name({Port, node()}) == :undefined
  end

  @tag unmodified: true
  test "native unavailability reaches public health and retains managed capacity", context do
    runtime = start_supervised!(SmolBox.child_spec(context.options))
    await(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end)
    assert {:ok, handle} = Machines.create(runtime, context.spec)
    assert {:ok, %{state: :stopped} = created} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = Machines.start(runtime, handle, created.version)
    assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 5000)
    {:ok, command} = Command.new(["unavailable"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: context.spec.scope,
        id: "unavailable-command",
        profile: context.spec.profile,
        artifact: context.spec.artifact,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, handle, spec)
    assert {:ok, %{state: :unknown, result: nil}} = SmolBox.await(runtime, execution, 5000)
    await(fn -> match?({:ok, [%{status: :unavailable}]}, SmolBox.workers(runtime)) end)
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)

    assert {:ok, %{backend_assignment: assignment, reservation: reservation}} =
             Machines.inspect(runtime, handle)

    assert assignment == created.backend_assignment and reservation != nil
    assert Enum.count(Package.received(context.native), &Map.has_key?(&1, "launch")) == 1
  end

  test "unapproved handshake cannot admit public work or consume a reservation", context do
    path = Path.join(context.native.package_path, "fixture.json")
    metadata = path |> File.read!() |> Jason.decode!() |> Map.put("wrong_hello", true)
    File.write!(path, Jason.encode!(metadata))
    runtime = start_supervised!(SmolBox.child_spec(context.options))
    assert {:ok, handle} = Machines.create(runtime, context.spec)
    Process.sleep(200)

    assert {:ok, %{state: :accepted, backend_assignment: nil, reservation: nil}} =
             Machines.inspect(runtime, handle)

    assert {:ok, [%{status: :unavailable}]} = SmolBox.workers(runtime)
    refute Enum.any?(Package.received(context.native), &Map.has_key?(&1, "operation"))
    assert {:ok, %{slots: 0}} = Memory.usage(context.store, context.native.id)
  end

  defp await(check, remaining \\ 200)
  defp await(_check, 0), do: flunk("public runtime did not settle")

  defp await(check, remaining) do
    if check.() do
      :ok
    else
      Process.sleep(25)
      await(check, remaining - 1)
    end
  end

  # A stale optimistic version proves no dispatch. Refresh that version only;
  # uncertain outcomes must never enter this retry path.
  defp lifecycle(runtime, handle, operation, version, attempts \\ 100) do
    case apply(Machines, operation, [runtime, handle, version]) do
      {:error, %{category: :stale_version, evidence: :not_dispatched}} when attempts > 0 ->
        {:ok, current} = Machines.inspect(runtime, handle)
        lifecycle(runtime, handle, operation, current.version, attempts - 1)

      result ->
        result
    end
  end
end
