defmodule SmolBox.Store.NativeCheckpointCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.{CheckpointContract, Config, Identity}
  alias SmolBox.Runtime.{NativeSupport, Target}
  alias SmolBox.Store.{Codec, CodecNativeCheckpoints, MachineOps, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Checkpoint,
    Command,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile
  }

  defp fixture(architecture \\ "x86_64", checkpointable \\ false) do
    {:ok, profile} = Profile.new("captured")

    {:ok, checkpoint} =
      Checkpoint.new(
        id: "idle-v1",
        sha256: String.duplicate("a", 64),
        architecture: architecture,
        platform: if(architecture == "aarch64", do: :macos, else: :linux),
        path: "/operator/idle.smolcheckpoint",
        profile: profile
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "checkpoint",
        id: "restored",
        artifact: Checkpoint.artifact(checkpoint),
        checkpointable: checkpointable,
        profile: profile
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: "worker",
        generation: String.duplicate("d", 32)
      },
      creation:
        %{
          "name" => "fresh-checkpoint",
          "owner_token" => String.duplicate("b", 64),
          "incarnation" => String.duplicate("c", 32),
          "source" => Checkpoint.artifact(checkpoint),
          "resources" => %{
            "cpus" => 1,
            "memory_mib" => 256,
            "storage_gib" => 1,
            "overlay_gib" => 1
          },
          "labels" => %{}
        }
        |> CheckpointContract.attach(spec)
    }

    {checkpoint, record, assignment}
  end

  defp reserved(checkpointable \\ false) do
    {checkpoint, record, assignment} = fixture("x86_64", checkpointable)

    {checkpoint,
     %{
       record
       | backend_assignment: assignment,
         worker_id: "worker",
         worker_generation: 1,
         machine_name: "fresh-checkpoint",
         reservation: Profile.resources(record.spec.profile),
         state: :creating,
         phase: :dispatching
     }}
  end

  defp observed(record, state, pid) do
    create = record.backend_assignment.creation

    receipt = %{
      "target_id" => "worker",
      "domain_generation" => record.backend_assignment.binding.generation,
      "name" => record.machine_name,
      "owner_token" => create["owner_token"],
      "incarnation" => create["incarnation"],
      "material_sha256" => String.duplicate("e", 64),
      "material" => %{
        "schema" => 2,
        "revision" => 0,
        "record_sha256" => String.duplicate("e", 64),
        "chain_sha256" => String.duplicate("f", 64),
        "operation_id" => nil,
        "request_sha256" => nil
      }
    }

    profile = record.spec.profile

    %Machine{
      name: record.machine_name,
      state: state,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: profile.storage_gb,
      overlay_gb: profile.overlay_gb,
      network: profile.network,
      backend_identity: %Identity{receipt: receipt, pid_identity: pid}
    }
  end

  test "native checkpoint identity is selective v22 and HTTP checkpoints keep their exact envelope" do
    {_checkpoint, record} = reserved()
    assert Assignment.valid?(record.backend_assignment)
    assert :ok = ManagedMachine.validate(record)
    assert CodecNativeCheckpoints.required?(record)
    assert {:ok, <<"smolbox-record-v22\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 2..21,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    http = %{record | backend_assignment: nil}
    assert :ok = ManagedMachine.validate(http)

    assert {:ok, <<"smolbox-record-v5\0", http_payload::binary>> = http_bytes} =
             Codec.encode(http)

    assert {:ok, ^http} = Codec.decode(http_bytes)
    legacy = :erlang.binary_to_term(http_payload, [:safe])
    refute Map.has_key?(legacy, :backend_assignment)
    refute Map.has_key?(legacy, :native_mounts)

    assert {:error, _} =
             Codec.decode(
               String.replace_prefix(http_bytes, "smolbox-record-v5", "smolbox-record-v22")
             )
  end

  test "checkpoint source cannot be rewritten as a local pack, remote source or caller path" do
    {_checkpoint, record} = reserved()
    create = record.backend_assignment.creation

    for changed <- [
          put_in(create, ["source", "id"], "other-id"),
          put_in(create, ["source", "sha256"], String.duplicate("f", 64)),
          put_in(create, ["source", "kind"], "oci"),
          update_in(create, ["source"], &Map.put(&1, "path", "/caller/input")),
          put_in(create, ["resources", "memory_mib"], 512),
          Map.put(create, "features", %{}),
          Map.put(create, "volume_mounts", [])
        ] do
      altered = %{record | backend_assignment: %{record.backend_assignment | creation: changed}}
      assert {:error, _} = Codec.encode(altered)
    end

    local =
      create
      |> Map.delete("source")
      |> Map.put("artifact", %{
        "path" => "/operator/input.smolmachine",
        "sha256" => record.spec.artifact["sha256"],
        "max_bytes" => 1024,
        "guest_platform" => "linux/amd64"
      })

    altered = %{record | backend_assignment: %{record.backend_assignment | creation: local}}
    assert Assignment.valid?(altered.backend_assignment)
    assert {:error, _} = Codec.encode(altered)
  end

  test "Memory atomically reserves checkpoint intent and rejects crossed source without capacity charge" do
    {_checkpoint, record, assignment} = fixture()
    store = start_supervised!(Memory)
    key = ManagedMachine.key(record)
    assert {:ok, %{native_checkpoint_sources: 1}} = Memory.capabilities(store)
    assert {:ok, _} = Memory.bind_backend(store, "worker", assignment.binding)
    assert {:ok, _} = Memory.claim_worker(store, "worker", "owner", 1000, 10_000)
    assert {:ok, _} = Memory.machine(store, :accept, [record, 10])
    assert {:ok, claimed} = Memory.machine(store, :claim, [key, "owner", 1000, 10_000])

    guard = %{
      owner: claimed.claim_owner,
      generation: claimed.generation,
      version: claimed.version
    }

    capacity = Profile.resources(record.spec.profile)
    crossed = put_in(assignment.creation["source"]["id"], "other-source")
    assert Assignment.valid?(crossed)

    assert {:error, _} =
             Memory.machine(store, :reserve, [
               key,
               guard,
               {"worker", "fresh-checkpoint", capacity, crossed},
               1000
             ])

    empty = Map.new(capacity, fn {key, _value} -> {key, 0} end)
    assert {:ok, ^empty} = Memory.usage(store, "worker")
    assert {:ok, ^claimed} = Memory.machine(store, :fetch, [key])

    assert {:ok, saved} =
             Memory.machine(store, :reserve, [
               key,
               guard,
               {"worker", "fresh-checkpoint", capacity, assignment},
               1000
             ])

    assert saved.backend_assignment == assignment
    assert {:ok, ^capacity} = Memory.usage(store, "worker")
    assert {:ok, [^saved], nil} = Memory.backend_assignments(store, "worker", nil, 10)
    assert {:ok, bytes} = Codec.encode(saved)
    assert {:ok, ^saved} = Codec.decode(bytes)
  end

  for checkpointable <- [false, true] do
    test "retained commands inherit checkpointable=#{checkpointable} authority without replay" do
      {_checkpoint, record} = reserved(unquote(checkpointable))

      machine = %{
        record
        | state: :running,
          phase: nil,
          operation: nil,
          created_machine: observed(record, :created, nil),
          observed_machine: observed(record, :running, [123, 456])
      }

      {:ok, command} = Command.new(["true"])

      {:ok, spec} =
        ExecutionSpec.new(
          scope: machine.scope,
          id: "command",
          artifact: machine.spec.artifact,
          profile: machine.spec.profile,
          command: command
        )

      {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
      {:ok, execution} = Execution.new(spec, fingerprint, 1000)
      assert {:ok, _machine, execution} = MachineOps.attach(machine, execution, 1000)
      assert execution.backend_assignment == machine.backend_assignment
      assert execution.reservation == nil
      assert :ok = Execution.validate(execution)
      assert {:ok, bytes} = Codec.encode(execution)

      assert String.starts_with?(
               bytes,
               if(unquote(checkpointable),
                 do: "smolbox-record-v23\0",
                 else: "smolbox-record-v22\0"
               )
             )

      assert {:ok, ^execution} = Codec.decode(bytes)
      assert {:error, _} = Execution.transition(execution, [backend_assignment: nil], 1000)
    end
  end

  test "current helpers reject checkpoint admission despite structural reader support" do
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    {checkpoint, record, assignment} = fixture(config.architecture)
    config = %{config | checkpoints: [checkpoint], profiles: [record.spec.profile]}
    assert :ok = Config.validate(config)
    refute Assignment.supports?(config, record.spec)
    refute Assignment.approved?(assignment, config, record.spec)
    assert {:error, _} = Assignment.new(config, record.spec, "fresh-checkpoint")
    assert {:error, _} = Assignment.qualification(config, record.spec)

    assert {:error, _} =
             Target.machine_spec(Target.normalize(config), record.spec, "fresh-checkpoint")
  end

  defmodule ReaderStore do
    def capabilities({store, marker}) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, marker)}
    end

    def bind_backend(_store, _worker, _binding), do: raise("must not enroll")
    def backend_assignments(_store, _worker, _cursor, _limit), do: raise("must not recover")
    def machine(_store, _operation, _arguments), do: raise("must not mutate")
  end

  test "optional checkpoint descriptors require source, capture and resolution readers before enrollment" do
    store = start_supervised!(Memory)
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    sdk = put_in(Config.sdk_identity(config)["feature_versions"]["checkpoints"], 1)
    config = %{config | sdk_identity: sdk}
    assert :ok = Config.validate(config)
    target = %Target{kind: :embedded, native_config: config}

    for marker <- [
          :native_checkpoint_sources,
          :native_checkpointable,
          :native_capture_histories,
          :native_capture_resolutions,
          :native_capture_cleanup,
          :native_capture_abort_sources
        ] do
      assert {:error, %{category: :unsupported_capability}} =
               NativeSupport.verify(%{workers: [target], store: {ReaderStore, {store, marker}}})
    end

    assert :ok = NativeSupport.verify(%{workers: [target], store: {Memory, store}})
  end

  for checkpointable <- [false, true] do
    test "fresh BEAM safely loads checkpointable=#{checkpointable} assignment vocabulary" do
      {_checkpoint, record} = reserved(unquote(checkpointable))
      assert {:ok, bytes} = Codec.encode(record)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-native-checkpoint-" <> Base.encode16(:crypto.strong_rand_bytes(16))
        )

      on_exit(fn -> File.rm(path) end)
      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code = ~S"""
      [path] = System.argv()
      case path |> File.read!() |> SmolBox.Store.Codec.decode() do
        {:ok, %{backend_assignment: %{version: 2, creation: %{"source" => %{"kind" => "checkpoint"}}}}} -> IO.puts("fresh-checkpoint")
        _ -> System.halt(1)
      end
      """

      assert {"fresh-checkpoint\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end

  test "checkpointable opt-in uses v23 and cannot disappear or enter old envelopes" do
    {_checkpoint, record, assignment} = fixture("x86_64", true)

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: "worker",
        worker_generation: 1,
        machine_name: "fresh-checkpoint",
        reservation: Profile.resources(record.spec.profile),
        state: :creating,
        phase: :dispatching
    }

    assert :ok = ManagedMachine.validate(record)
    assert {:ok, <<"smolbox-record-v23\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 2..22,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    for value <- [false, nil] do
      altered = put_in(record.backend_assignment.creation["checkpointable"], value)
      assert {:error, _} = Codec.encode(altered)
    end

    missing = %{
      record
      | backend_assignment: %{
          assignment
          | creation: Map.delete(assignment.creation, "checkpointable")
        }
    }

    assert {:error, _} = Codec.encode(missing)
    http = %{record | backend_assignment: nil}
    assert {:ok, <<"smolbox-record-v12\0", _::binary>> = http_bytes} = Codec.encode(http)
    assert {:ok, ^http} = Codec.decode(http_bytes)
  end

  test "Memory persists checkpointable opt-in atomically and rejects its omission" do
    {_checkpoint, record, assignment} = fixture("x86_64", true)
    store = start_supervised!(Memory)
    key = ManagedMachine.key(record)
    assert {:ok, %{native_checkpointable: 1}} = Memory.capabilities(store)
    assert {:ok, _} = Memory.bind_backend(store, "worker", assignment.binding)
    assert {:ok, _} = Memory.claim_worker(store, "worker", "owner", 1000, 10_000)
    assert {:ok, _} = Memory.machine(store, :accept, [record, 10])
    assert {:ok, claimed} = Memory.machine(store, :claim, [key, "owner", 1000, 10_000])

    guard = %{
      owner: claimed.claim_owner,
      generation: claimed.generation,
      version: claimed.version
    }

    capacity = Profile.resources(record.spec.profile)
    ordinary = %{assignment | creation: Map.delete(assignment.creation, "checkpointable")}

    assert {:error, _} =
             Memory.machine(store, :reserve, [
               key,
               guard,
               {"worker", "fresh-checkpoint", capacity, ordinary},
               1000
             ])

    assert {:ok, ^claimed} = Memory.machine(store, :fetch, [key])

    assert {:ok, saved} =
             Memory.machine(store, :reserve, [
               key,
               guard,
               {"worker", "fresh-checkpoint", capacity, assignment},
               1000
             ])

    assert saved.backend_assignment == assignment
    assert {:ok, ^capacity} = Memory.usage(store, "worker")
    assert {:ok, bytes} = Codec.encode(saved)
    assert {:ok, ^saved} = Codec.decode(bytes)
  end
end
