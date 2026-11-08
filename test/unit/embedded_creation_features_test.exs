defmodule SmolBox.EmbeddedCreationFeaturesTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Backend,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    PortMapping,
    Runtime,
    TestArtifacts,
    Workload
  }

  alias SmolBox.Backend.{Assignment, Embedded, EmbeddedContext, EmbeddedReply}
  alias SmolBox.Embedded.{Config, CreationFeatures, Launch, Port, Protocol, Request}
  alias SmolBox.Runtime.Target
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule NoPortsStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :managed_ports)}
    end
  end

  setup do
    native = Package.create(protocol_major: 2, backend: true, persistent_backend: true)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})
    %{native: native, store: store, artifacts: artifacts}
  end

  test "network, ports and workload persist through ordinary lifecycle with typed observations",
       context do
    {:ok, policy} = NetworkPolicy.new(hosts: ["api.example.com"], cidrs: ["192.0.2.0/24"])
    profile = %{hd(context.native.profiles) | network: policy}
    native = %{context.native | profiles: [profile]}

    {:ok, workload} =
      Workload.new(
        cmd: ["/bin/app", "literal; $(text)"],
        env: [{"PRIVATE", "value"}],
        workdir: "/app"
      )

    spec = spec(native, workload: workload)
    runtime = runtime(context, native)
    {:ok, handle} = Machines.create(runtime, spec)
    {:ok, created} = Machines.await(runtime, handle, 5000)
    assert created.state == :stopped and created.reserved_ports == [28_731]
    assert created.created_machine.network == policy
    assert created.created_machine.ports == spec.ports
    assert created.backend_assignment.version == 2
    assert created.backend_assignment.creation["features"] == CreationFeatures.from_spec(spec)
    assert {:ok, encoded} = Codec.encode(created)
    assert String.starts_with?(encoded, "smolbox-record-v17\0")
    assert {:ok, ^created} = Codec.decode(encoded)
    connection = Target.connection(Target.normalize(native), created)
    assert {:ok, measurements} = Backend.machine_measurements(connection, created.machine_name)
    assert measurements.machine.network == policy and measurements.machine.ports == spec.ports

    assert {:ok, inventory} =
             Backend.list(elem(Embedded.reference(native, connection.context.server), 1))

    assert hd(inventory).network == policy and hd(inventory).ports == spec.ports
    assert hd(inventory).backend_identity == nil

    changed = %{spec | workload: %{workload | cmd: ["different"]}}
    assert {:error, %{category: :identity_conflict}} = Machines.create(runtime, changed)
    assert :ok = SmolBox.drain_worker(runtime, native.id)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :stop)

    assert {:ok, %{state: :stopped, reserved_ports: [28_731]} = stopped} =
             Machines.await(runtime, handle, 5000)

    assert {:ok, stopped_bytes} = Codec.encode(stopped)
    assert {:ok, ^stopped} = Codec.decode(stopped_bytes)
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, native.id)
    stop_supervised!({Runtime, __MODULE__})
    runtime = runtime(context, native, [], :draining)
    assert {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.backend_assignment == stopped.backend_assignment
    assert recovered.created_machine == stopped.created_machine
    assert recovered.reserved_ports == stopped.reserved_ports
    assert recovered.reservation == stopped.reservation
    assert {:ok, _} = lifecycle(runtime, handle, :delete)

    assert {:ok, %{state: :deleted, reserved_ports: [], reservation: nil}} =
             Machines.await(runtime, handle, 5000)

    assert {:ok, %{slots: 0}} = Memory.usage(context.store, native.id)
    requests = operations(native)
    assert Enum.count(requests, &(&1["operation"] == "create")) == 1

    assert Enum.any?(
             requests,
             &(&1["operation"] == "qualify_creation" and
                 &1["features"] == CreationFeatures.from_spec(spec))
           )
  end

  test "offline inbound ports retain no egress and conflicting reservations cannot allocate",
       context do
    native = %{context.native | capacity: %{slots: 2, cpus: 2, memory_mb: 1024, disk_gb: 4}}
    runtime = runtime(context, native)
    first = spec(native)
    {:ok, handle} = Machines.create(runtime, first)

    assert {:ok, %{state: :stopped, created_machine: machine}} =
             Machines.await(runtime, handle, 5000)

    assert machine.network == :offline and machine.ports == first.ports
    {:ok, conflict} = Machines.create(runtime, %{first | id: "conflicting"})

    assert {:ok,
            %{
              state: :conflict,
              worker_id: nil,
              reservation: nil,
              reserved_ports: [],
              last_error: error
            }} =
             Machines.await(runtime, conflict, 5000)

    assert error.category == :port_conflict
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, native.id)
    assert Enum.count(operations(native), &(&1["operation"] == "create")) == 1
    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  test "store capability rejects mapped ports before durable acceptance or dispatch", context do
    runtime = runtime(context, context.native, store: {NoPortsStore, context.store})

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(runtime, spec(context.native))

    assert {:error, %{category: :not_found}} =
             Memory.fetch(context.store, {"creation", "retained"})

    refute Enum.any?(
             operations(context.native),
             &(&1["operation"] in ~w(create qualify_creation))
           )
  end

  test "creation intent cannot expand approved features or mislabel legacy schemas", context do
    spec = spec(context.native)
    {:ok, assignment} = Assignment.new(context.native, spec, "candidate")
    assert Assignment.approved?(assignment, context.native, spec)
    assert Request.valid?(%{"operation" => "create", "create" => assignment.creation}, 1000, 2)
    refute Request.valid?(%{"operation" => "create", "create" => assignment.creation}, 1000, 1)

    changed =
      put_in(assignment.creation, ["features", "ports"], [%{"host" => 28_732, "guest" => 80}])

    refute Assignment.approved?(%{assignment | creation: changed}, context.native, spec)
    sdk = Config.sdk_identity(context.native)

    old = %{
      context.native
      | sdk_identity: %{
          sdk
          | "feature_versions" =>
              Map.drop(sdk["feature_versions"], ~w(networking ports workloads))
        }
    }

    assert :ok = Config.validate(old)
    refute Assignment.supports?(old, spec)
    assert {:error, %{category: :unsupported_capability}} = Assignment.new(old, spec, "candidate")
    features = assignment.creation["features"]
    refute CreationFeatures.valid?(put_in(features, ["network", "hosts"], ["api.example.com"]))
    refute CreationFeatures.valid?(Map.put(features, "extra", true))
    assert Package.received(context.native) == []
  end

  test "mismatched actual network or port observations cannot satisfy owned lifecycle", context do
    runtime = runtime(context, context.native)
    {:ok, handle} = Machines.create(runtime, spec(context.native))
    {:ok, record} = Machines.await(runtime, handle, 5000)
    reference = Target.connection(Target.normalize(context.native), record)

    observed = %{
      "state" => "stopped",
      "resources" => record.backend_assignment.creation["resources"],
      "pid_identity" => nil,
      "configuration" => %{
        "network" => CreationFeatures.network(:offline),
        "ports" => [%{"host" => 28_732, "guest" => 80}],
        "backend" => "virtio-net"
      }
    }

    outcome = %{"result" => "observed", "observation" => observed}
    assert Protocol.valid_outcome?(outcome, 2)
    refute Protocol.valid_outcome?(outcome, 1)

    conflict = %{
      "result" => "error",
      "code" => "port_conflict",
      "dispatch" => "may_have_dispatched"
    }

    assert Protocol.valid_outcome?(conflict, 2)
    refute Protocol.valid_outcome?(conflict, 1)

    assert {:error, %{category: :port_conflict, evidence: :dispatch_uncertain}} =
             EmbeddedReply.decode(
               reference.context,
               :start,
               %{},
               {:ok, conflict, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
             )

    assert {:error, %{category: :identity_conflict, evidence: :dispatch_uncertain}} =
             EmbeddedReply.decode(
               reference.context,
               :inspect_machine,
               %{},
               {:ok, outcome, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
             )

    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  test "publisher address is explicit canonical IPv4 and bound into private launch config",
       context do
    assert context.native.publish_address == "127.0.0.1"

    for value <- ["localhost", "::1", "127.000.0.1", "127.0.0.1:8080", nil] do
      assert {:error, %{category: :validation}} =
               Config.validate(%{context.native | publish_address: value})
    end

    native = %{context.native | publish_address: "0.0.0.0"}
    assert :ok = Config.validate(native)
    {:ok, directory} = Launch.directory()
    on_exit(fn -> Launch.cleanup(directory) end)
    assert {:ok, prepared} = Launch.prepare(native, directory)
    assert Jason.decode!(File.read!(prepared.config_path))["publish_address"] == "0.0.0.0"
    assert Package.received(native) == []
  end

  test "large escaped workload reaches public creation without changing durable intent",
       context do
    env = for index <- 1..64, do: {"K#{index}", String.duplicate("\x01", 8192)}
    {:ok, workload} = Workload.new(cmd: ["/bin/app"], env: env)
    spec = spec(context.native, workload: workload)
    runtime = runtime(context, context.native)
    assert {:ok, handle} = Machines.create(runtime, spec)
    assert {:ok, %{state: :stopped} = record} = Machines.await(runtime, handle, 5000)
    assert record.spec.workload == workload
    assert record.backend_assignment.creation["features"] == CreationFeatures.from_spec(spec)
    assert {:ok, encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)
    requests = operations(context.native)

    for name <- ~w(qualify_creation create) do
      request = Enum.find(requests, &(&1["operation"] == name))
      fields = if name == "create", do: request["create"], else: request
      refute Map.has_key?(fields, "features")
      assert fields["features_payload"]["schema"] == 1
      assert match?([_, _ | _], fields["features_payload"]["chunks"])
    end

    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted, reserved_ports: []}} = Machines.await(runtime, handle, 5000)
  end

  test "managed buffered stdin preserves UTF-8 NUL bytes Exit evidence and codec authority",
       context do
    runtime = runtime(context, context.native)
    {:ok, workload} = Workload.new(cmd: ["/bin/app"], env: [{"STARTUP", "value"}])
    machine_spec = spec(context.native, workload: workload)
    assert {:ok, handle} = Machines.create(runtime, machine_spec)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 5000)
    stdin = "hé\0" <> String.duplicate("x", 8192)
    {:ok, command} = SmolBox.Command.new(["stdin_echo"], stdin: stdin)

    {:ok, execution_spec} =
      SmolBox.ExecutionSpec.new(
        scope: machine_spec.scope,
        id: "stdin",
        profile: machine_spec.profile,
        artifact: machine_spec.artifact,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, handle, execution_spec)

    assert {:ok, %{state: :completed, result: result} = record} =
             SmolBox.await(runtime, execution, 5000)

    assert result.stdout == stdin and result.stderr == <<101, 114, 114, 0, 254>> and
             result.exit_code == 7

    assert {:ok, encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)

    assert record.backend_assignment.creation["features"] ==
             CreationFeatures.from_spec(machine_spec)

    assert record.created_machine.ports == machine_spec.ports

    assert Assignment.approved?(
             record.backend_assignment,
             context.native,
             record.spec,
             record.managed_machine
           )

    refute Assignment.approved?(record.backend_assignment, context.native, record.spec)

    refute Assignment.approved?(
             record.backend_assignment,
             context.native,
             record.spec,
             {"other-scope", machine_spec.id}
           )

    assert {:error, _} =
             SmolBox.Execution.validate(%{
               record
               | created_machine: %{record.created_machine | ports: []}
             })

    refute Assignment.record_valid?(%{
             record
             | created_machine: %{record.created_machine | network: nil}
           })

    connection = Target.connection(Target.normalize(context.native), record)
    refute EmbeddedContext.scoped?(%{connection.context | identity: nil})
    assert {:ok, observed} = Backend.inspect_machine(connection, record.machine_name)
    assert observed.ports == machine_spec.ports
    assert {:ok, measurements} = Backend.machine_measurements(connection, record.machine_name)
    assert measurements.machine.ports == machine_spec.ports
    requests = operations(context.native)
    assert Enum.count(requests, &(&1["operation"] == "exec_buffered")) == 1
    request = Enum.find(requests, &(&1["operation"] == "exec_buffered"))
    assert request["command_payload"]["schema"] == 1
    refute Map.has_key?(request, "command")
    await(fn -> match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, handle)) end)
    assert {:ok, _} = lifecycle(runtime, handle, :stop)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  test "managed streaming preserves full command bounds binary events Exit and durable creation",
       context do
    runtime = runtime(context, context.native)
    {:ok, workload} = Workload.new(cmd: ["/bin/app"])
    machine_spec = spec(context.native, workload: workload)
    {:ok, handle} = Machines.create(runtime, machine_spec)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running} = machine} = Machines.await(runtime, handle, 5000)
    env = for index <- 1..64, do: {"K#{index}", String.duplicate("\x01", 8192)}

    argv =
      ["echo" | List.duplicate(String.duplicate("\x01", 16_384), 3)] ++
        [String.duplicate("\x01", 16_380)]

    {:ok, command} = SmolBox.Command.new(argv, env: env)

    {:ok, intent} =
      SmolBox.ExecutionSpec.new(
        scope: machine_spec.scope,
        id: "large-stream",
        profile: machine_spec.profile,
        artifact: machine_spec.artifact,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, handle, intent)

    assert {:ok, %{state: :completed, result: result} = record} =
             SmolBox.await(runtime, execution, 5000)

    assert result.stdout == <<111, 117, 116, 0, 255>>
    assert result.stderr == <<101, 114, 114, 0, 254>>
    assert result.exit_code == 7
    assert record.spec.command == command
    assert record.backend_assignment == machine.backend_assignment
    assert record.created_machine.ports == machine_spec.ports
    assert {:ok, bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
    requests = operations(context.native)
    assert Enum.count(requests, &(&1["operation"] == "exec_stream")) == 1
    refute Enum.any?(requests, &(&1["operation"] in ~w(exec exec_buffered)))
    request = Enum.find(requests, &(&1["operation"] == "exec_stream"))
    refute Map.has_key?(request, "command")
    assert match?([_, _ | _], request["command_payload"]["chunks"])
    await(fn -> match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, handle)) end)
    connection = Target.connection(Target.normalize(context.native), machine)
    observer = self()

    assert {:ok, ^result} =
             Backend.exec_stream(connection, machine.machine_name, command,
               on_event: fn event -> send(observer, {:stream, event}) end
             )

    assert_receive {:stream, {:stdout, <<111, 117, 116, 0, 255>>}}
    assert_receive {:stream, {:stderr, <<101, 114, 114, 0, 254>>}}
    assert_receive {:stream, {:exit, 7}}

    assert {:ok, ^result} =
             Backend.exec_stream(connection, machine.machine_name, command,
               on_event: fn event ->
                 send(observer, {:detached_stream, event})
                 raise "observer"
               end
             )

    assert_receive {:detached_stream, {:stdout, _}}
    refute_receive {:detached_stream, _}, 20

    assert {:error, %{category: :expired, exit_code: 7, evidence: :exited},
            %{exit_code: 7, truncated: true}} =
             Backend.exec_stream(
               Backend.bounded(connection, timeout_ms: 500),
               machine.machine_name,
               command,
               on_event: fn
                 {:exit, 7} -> Process.sleep(750)
                 _event -> :ok
               end
             )

    assert {:ok, _} = lifecycle(runtime, handle, :stop)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  test "older streaming descriptor rejects expanded nil-stdin intent before dispatch", context do
    native = context.native
    native = update_in(native.sdk_identity["feature_versions"], &Map.delete(&1, "streaming_exec"))

    {:ok, small} = SmolBox.Command.new(["echo"])
    env = for n <- 1..64, do: {"K#{n}", String.duplicate("x", 8192)}
    {:ok, large} = SmolBox.Command.new(["echo"], env: env)

    for {command, supported} <- [{small, true}, {large, false}] do
      {:ok, intent} =
        SmolBox.ExecutionSpec.new(
          scope: "creation",
          id: "legacy-stream",
          profile: hd(native.profiles),
          artifact: hd(native.artifacts) |> Map.take(~w(id sha256 architecture)),
          command: command
        )

      assert Assignment.supports?(native, intent) == supported

      if not supported,
        do:
          assert(
            {:error, %{category: :unsupported_capability}} =
              Assignment.new(native, intent, "candidate")
          )
    end

    assert Package.received(context.native) == []
  end

  test "retained background execution persists launch evidence without foreground Exit",
       context do
    runtime = runtime(context, context.native)
    machine_spec = spec(context.native)
    {:ok, handle} = Machines.create(runtime, machine_spec)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running} = machine} = Machines.await(runtime, handle, 5000)
    {:ok, command} = SmolBox.Command.new(["/bin/sleep", "600"], background: true)
    assert command.timeout_secs == nil and command.stdin == nil

    {:ok, intent} =
      SmolBox.ExecutionSpec.new(
        scope: machine_spec.scope,
        id: "launch",
        profile: machine_spec.profile,
        artifact: machine_spec.artifact,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, handle, intent)

    assert {:ok,
            %{state: :launched, evidence: :launched, result: %SmolBox.LaunchResult{pid: 4242}} =
              record} =
             SmolBox.await(runtime, execution, 5000)

    assert record.backend_assignment == machine.backend_assignment
    assert {:ok, encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)
    assert record.spec.command == command
    requests = operations(context.native)
    assert Enum.count(requests, &(&1["operation"] == "exec_background")) == 1
    refute Enum.any?(requests, &(&1["operation"] in ~w(exec exec_buffered)))
    request = Enum.find(requests, &(&1["operation"] == "exec_background"))
    assert request["command_payload"]["schema"] == 1
    await(fn -> match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, handle)) end)
    connection = Target.connection(Target.normalize(context.native), machine)

    assert {:error, %{category: :unsupported_capability}} =
             Backend.exec_stream(connection, machine.machine_name, command)

    assert {:error, %{category: :unsupported_capability}} =
             Backend.exec(connection, machine.machine_name, command, on_event: fn _ -> :ok end)

    assert {:ok, _} = lifecycle(runtime, handle, :stop)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
    assert Enum.count(operations(context.native), &(&1["operation"] == "exec_background")) == 1
  end

  test "uncertain background launch keeps the command slot and never replays after graceful replacement",
       context do
    runtime = runtime(context, context.native)
    machine_spec = spec(context.native)
    {:ok, handle} = Machines.create(runtime, machine_spec)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running}} = Machines.await(runtime, handle, 5000)
    {:ok, command} = SmolBox.Command.new(["launch_unknown"], background: true)

    {:ok, intent} =
      SmolBox.ExecutionSpec.new(
        scope: machine_spec.scope,
        id: "uncertain-launch",
        profile: machine_spec.profile,
        artifact: machine_spec.artifact,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, handle, intent)

    assert {:ok, %{state: :unknown, result: nil, evidence: :unknown} = record} =
             SmolBox.await(runtime, execution, 5000)

    await(fn -> match?({:ok, %{state: :unknown}}, Machines.inspect(runtime, handle)) end)
    assert {:ok, machine} = Machines.inspect(runtime, handle)
    assert machine.active_execution == SmolBox.Execution.key(record)
    assert machine.reservation != nil and machine.reserved_ports == [28_731]
    assert {:ok, bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
    stop_supervised!({Runtime, __MODULE__})
    runtime = runtime(context, context.native)
    assert {:ok, recovered} = SmolBox.fetch(runtime, record.scope, record.id)

    assert recovered.state == :unknown and recovered.result == nil and
             recovered.evidence == :unknown

    assert {:ok, retained} = Machines.inspect(runtime, handle)
    assert retained.active_execution == machine.active_execution
    assert retained.reservation == machine.reservation
    assert retained.reserved_ports == machine.reserved_ports
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert Enum.count(operations(context.native), &(&1["operation"] == "exec_background")) == 1
  end

  test "console tails callbacks and follow preserve machine intent and resource accounting",
       context do
    runtime = runtime(context, context.native)
    {:ok, handle} = Machines.create(runtime, spec(context.native))
    assert {:ok, %{state: :stopped} = created} = Machines.await(runtime, handle, 5000)
    assert {:error, %{category: :not_found}} = Machines.logs(runtime, handle)
    assert {:ok, _} = lifecycle(runtime, handle, :start)
    assert {:ok, %{state: :running} = running} = Machines.await(runtime, handle, 5000)
    connection = Target.connection(Target.normalize(context.native), running)

    assert {:ok, %SmolBox.LogResult{lines: ["boot", "", "hé\0line"]}} =
             Backend.logs(connection, running.machine_name)

    observer = self()
    callback = fn {:log, line} -> send(observer, {:console, line}) end

    assert {:ok,
            %SmolBox.LogResult{lines: ["", "hé\0line"], source: :console, encoding: :lossy_utf8}} =
             Machines.logs(runtime, handle, tail: 2, on_event: callback)

    assert_receive {:console, ""}
    assert_receive {:console, "hé\0line"}
    assert {:ok, %SmolBox.LogResult{lines: []}} = Machines.logs(runtime, handle, tail: 0)

    failing = fn {:log, line} ->
      send(observer, {:detached, line})
      raise "observer"
    end

    assert {:ok, %SmolBox.LogResult{lines: ["boot", "", "hé\0line"]}} =
             Machines.logs(runtime, handle, on_event: failing)

    assert_receive {:detached, "boot"}
    refute_receive {:detached, _}, 20

    assert {:error, %{category: :output_limit}} =
             Machines.logs(runtime, handle, max_output_bytes: 1)

    assert {:error, %{category: :expired}} =
             Machines.logs(runtime, handle,
               tail: 0,
               follow: true,
               timeout_ms: 1000,
               on_event: callback
             )

    assert_receive {:console, "follow"}
    assert_receive {:console, "next"}
    assert {:ok, after_logs} = Machines.inspect(runtime, handle)
    assert after_logs.active_execution == nil
    assert after_logs.backend_assignment == created.backend_assignment

    assert after_logs.reservation == running.reservation and
             after_logs.reserved_ports == running.reserved_ports

    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
    assert {:ok, _} = lifecycle(runtime, handle, :stop)
    assert {:ok, %{state: :stopped}} = Machines.await(runtime, handle, 5000)

    assert {:ok, %SmolBox.LogResult{lines: ["hé\0line"]}} =
             Machines.logs(runtime, handle, tail: 1)

    assert {:ok, _} = lifecycle(runtime, handle, :delete)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  defp spec(native, extra \\ []) do
    {:ok, mapping} = PortMapping.new(host: 28_731, guest: 80)

    {:ok, value} =
      ManagedMachineSpec.new(
        Keyword.merge(
          [
            scope: "creation",
            id: "retained",
            profile: hd(native.profiles),
            artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture)),
            ports: [mapping]
          ],
          extra
        )
      )

    value
  end

  defp runtime(context, native, extra \\ [], status \\ :ready) do
    value =
      start_supervised!(
        SmolBox.child_spec(
          Keyword.merge(
            [
              name: __MODULE__,
              namespace: "creation",
              mode: :ephemeral,
              store: {Memory, context.store},
              artifact_store: {TestArtifacts, context.artifacts},
              fingerprint_key: String.duplicate("k", 32),
              workers: [native],
              lease_ms: 1000,
              poll_ms: 20
            ],
            extra
          )
        )
      )

    await(fn -> match?({:ok, [%{status: ^status}]}, SmolBox.workers(value)) end)

    await(fn ->
      match?({:ok, %{status: :ready}}, Port.health(:global.whereis_name({Port, node()})))
    end)

    value
  end

  defp operations(native),
    do:
      for(
        message <- Package.received(native),
        message["type"] == "request",
        do: message["operation"]
      )

  defp lifecycle(runtime, handle, action, attempts \\ 100) do
    {:ok, record} = Machines.inspect(runtime, handle)

    case apply(Machines, action, [runtime, handle, record.version]) do
      {:error, %{category: :stale_version, evidence: :not_dispatched}} when attempts > 0 ->
        Process.sleep(10)
        lifecycle(runtime, handle, action, attempts - 1)

      value ->
        value
    end
  end

  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("ordinary creation fixture did not settle")

  defp await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          await(check, attempts - 1)
        )
  end
end
