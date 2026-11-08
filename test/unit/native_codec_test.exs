defmodule SmolBox.Store.NativeCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.Embedded.Identity
  alias SmolBox.Store.{Codec, CodecNative, MachineOps}

  alias SmolBox.{
    Command,
    Execution,
    ExecutionSpec,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile
  }

  alias SmolBox.Terminal.{Result, Spec}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defp fixture do
    config = Package.create()
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    profile = hd(config.profiles)
    artifact = config.artifacts |> hd() |> Map.take(~w(id sha256 architecture))

    {:ok, spec} =
      ManagedMachineSpec.new(scope: "native", id: "vm", artifact: artifact, profile: profile)

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    {:ok, assignment} = Assignment.new(config, spec, "owned-native")

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: config.id,
        worker_generation: 1,
        machine_name: "owned-native",
        reservation: Profile.resources(profile),
        state: :creating,
        phase: :dispatching
    }

    {config, record}
  end

  defp identity(record, pid \\ nil) do
    assignment = record.backend_assignment

    receipt = %{
      "target_id" => assignment.binding.target_id,
      "domain_generation" => assignment.binding.generation,
      "name" => record.machine_name,
      "owner_token" => assignment.creation["owner_token"],
      "incarnation" => assignment.creation["incarnation"],
      "material_sha256" => String.duplicate("a", 64)
    }

    %Identity{receipt: receipt, pid_identity: pid}
  end

  defp observation(record, state \\ :created, pid \\ nil) do
    profile = record.spec.profile

    %Machine{
      name: record.machine_name,
      state: state,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: profile.storage_gb,
      overlay_gb: profile.overlay_gb,
      backend_identity: identity(record, pid)
    }
  end

  test "native creation intent and receipt selectively use v16 without runtime handles" do
    {_config, record} = fixture()
    assert :ok = ManagedMachine.validate(record)
    assert {:ok, <<"smolbox-record-v16\0", _::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    created = %{
      record
      | created_machine: observation(record),
        state: :created,
        operation: nil,
        phase: nil
    }

    assert :ok = ManagedMachine.validate(created)
    assert {:ok, bytes} = Codec.encode(created)
    assert {:ok, ^created} = Codec.decode(bytes)
    assert created.created_machine.created_at == nil
    refute Map.has_key?(created.backend_assignment.binding, :bridge)
    refute Map.has_key?(created.backend_assignment.binding, :epoch)

    refute inspect(created.backend_assignment) =~
             record.backend_assignment.creation["owner_token"]

    refute inspect(created.created_machine.backend_identity) =~
             record.backend_assignment.creation["owner_token"]
  end

  test "versioned material authority selectively uses v17 and cannot downgrade to legacy envelopes" do
    {config, record} = fixture()
    assignment = %{record.backend_assignment | version: 2}
    versioned = %{record | backend_assignment: assignment}
    assert :ok = ManagedMachine.validate(versioned)
    assert {:ok, <<"smolbox-record-v17\0", _::binary>> = bytes} = Codec.encode(versioned)
    assert {:ok, ^versioned} = Codec.decode(bytes)
    refute Assignment.approved?(assignment, config, versioned.spec)
    observed = observation(versioned)
    old_receipt = observed.backend_identity.receipt

    material = %{
      "schema" => 2,
      "revision" => 0,
      "record_sha256" => old_receipt["material_sha256"],
      "chain_sha256" => String.duplicate("b", 64),
      "operation_id" => nil,
      "request_sha256" => nil
    }

    observed =
      put_in(observed.backend_identity.receipt, Map.put(old_receipt, "material", material))

    created = %{
      versioned
      | created_machine: observed,
        state: :created,
        operation: nil,
        phase: nil
    }

    assert :ok = ManagedMachine.validate(created)
    assert {:ok, <<"smolbox-record-v17\0", payload::binary>> = bytes} = Codec.encode(created)
    assert {:ok, ^created} = Codec.decode(bytes)

    for prefix <- ["smolbox-record-v16\0", "smolbox-record-v15\0", "smolbox-record-v4\0"] do
      assert {:error, _} = Codec.decode(prefix <> payload)
    end

    assert {:error, _} = Codec.decode(bytes <> "trailing")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v17\0" <> :erlang.term_to_binary(created, compressed: 9)
             )

    assert {:error, _} = Codec.encode(%{created | backend_assignment: record.backend_assignment})
    stripped = put_in(created.created_machine.backend_identity.receipt, old_receipt)
    assert {:error, _} = Codec.encode(stripped)

    # Preserve the previous v17 structural vocabulary; decoding an old opaque
    # advanced receipt does not promote it into a qualified growth history.
    advanced =
      created
      |> put_in(
        [
          Access.key(:created_machine),
          Access.key(:backend_identity),
          Access.key(:receipt),
          "material",
          "revision"
        ],
        1
      )
      |> put_in(
        [
          Access.key(:created_machine),
          Access.key(:backend_identity),
          Access.key(:receipt),
          "material",
          "operation_id"
        ],
        "legacy-material"
      )
      |> put_in(
        [
          Access.key(:created_machine),
          Access.key(:backend_identity),
          Access.key(:receipt),
          "material",
          "request_sha256"
        ],
        String.duplicate("c", 64)
      )

    assert {:ok, <<"smolbox-record-v17\0", _::binary>> = advanced_bytes} = Codec.encode(advanced)
    assert {:ok, ^advanced} = Codec.decode(advanced_bytes)
  end

  test "v16 omits the new default exactly and v17 rejects legacy records" do
    {_config, record} = fixture()
    assert record.backend_assignment.version == 1

    historical =
      put_in(record.backend_assignment, Map.delete(record.backend_assignment, :version))
      |> Map.delete(:native_mounts)

    expected = "smolbox-record-v16\0" <> :erlang.term_to_binary(historical)
    assert {:ok, ^expected} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(expected)
    assert {:error, _} = Codec.decode("smolbox-record-v17\0" <> :erlang.term_to_binary(record))
    assert {:error, _} = Codec.decode("smolbox-record-v16\0" <> :erlang.term_to_binary(record))
    assert {:error, _} = Codec.encode(put_in(record.backend_assignment.version, 3))
  end

  test "a fresh BEAM reads v17 material proofs using the fixed schema vocabulary" do
    {config, record} = fixture()
    record = put_in(record.backend_assignment.version, 2)
    observed = observation(record)
    receipt = observed.backend_identity.receipt

    proof = %{
      "schema" => 2,
      "revision" => 0,
      "record_sha256" => receipt["material_sha256"],
      "chain_sha256" => String.duplicate("b", 64),
      "operation_id" => nil,
      "request_sha256" => nil
    }

    observed = put_in(observed.backend_identity.receipt, Map.put(receipt, "material", proof))
    record = %{record | created_machine: observed, state: :created, operation: nil, phase: nil}
    {:ok, bytes} = Codec.encode(record)
    path = Path.join(config.package_path, "material-record.etf")
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code =
      "[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do " <>
        "{:ok, %{backend_assignment: %{version: 2}, created_machine: %{backend_identity: " <>
        ~S|%{receipt: %{"material" => %{"schema" => 2}}}}}} -> IO.puts("fresh-material"); | <>
        "_ -> System.halt(1) end"

    assert {"fresh-material\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "domain, intent, receipt and material identity cannot be mixed or downgraded" do
    {_config, record} = fixture()

    created = %{
      record
      | created_machine: observation(record),
        state: :created,
        operation: nil,
        phase: nil
    }

    for key <- ~w(target_id domain_generation name owner_token incarnation) do
      value = created.created_machine.backend_identity.receipt[key]
      first = if String.starts_with?(value, "0"), do: "1", else: "0"

      altered =
        put_in(
          created.created_machine.backend_identity.receipt[key],
          first <> binary_part(value, 1, byte_size(value) - 1)
        )

      assert {:error, _} = ManagedMachine.validate(altered)
      assert {:error, _} = Codec.encode(altered)
    end

    for changed <- [
          %{created | backend_assignment: nil},
          %{created | worker_id: "another-target"},
          %{created | machine_name: "another-name"},
          %{created | created_machine: %{created.created_machine | backend_identity: nil}},
          %{created | created_machine: %{created.created_machine | created_at: 1000}},
          %{
            created
            | backend_assignment: %{
                created.backend_assignment
                | binding: Map.put(created.backend_assignment.binding, :bridge, :port)
              }
          }
        ] do
      assert {:error, _} = Codec.encode(changed)
    end

    {:ok, <<"smolbox-record-v16\0", payload::binary>>} = Codec.encode(created)

    for version <- 1..15,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    assert {:error, _} = Codec.decode("smolbox-record-v16\0" <> payload <> "extra")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v16\0" <> :erlang.term_to_binary(created, compressed: 9)
             )
  end

  test "VMM process identity may change without changing durable machine incarnation" do
    {_config, record} = fixture()
    first = observation(record)
    running = observation(record, :running, [100, 12_345])
    restarted = observation(record, :running, [200, 23_456])
    assert Machine.same_incarnation?(first, running)
    assert Machine.same_incarnation?(running, restarted)

    changed =
      put_in(restarted.backend_identity.receipt["material_sha256"], String.duplicate("b", 64))

    refute Machine.same_incarnation?(first, changed)

    assert :ok =
             ManagedMachine.validate(%{
               record
               | created_machine: first,
                 observed_machine: running,
                 state: :running,
                 operation: nil,
                 phase: nil
             })

    assert {:error, _} =
             ManagedMachine.validate(%{
               record
               | created_machine: first,
                 observed_machine: %{
                   running
                   | backend_identity: %{running.backend_identity | pid_identity: nil}
                 },
                 state: :running,
                 operation: nil,
                 phase: nil
             })

    assert {:error, _} =
             ManagedMachine.validate(%{
               record
               | created_machine: first,
                 observed_machine: %{running | state: :stopped},
                 state: :stopped,
                 operation: nil,
                 phase: nil
             })
  end

  test "HTTP writes retain their prior payload and reject future fields even when empty" do
    {_config, native} = fixture()
    {:ok, legacy} = ManagedMachine.new(native.spec, native.fingerprint, 1000)
    assert {:ok, <<"smolbox-record-v5\0", payload::binary>> = bytes} = Codec.encode(legacy)
    decoded = :erlang.binary_to_term(payload)
    refute Map.has_key?(decoded, :backend_assignment)
    assert {:ok, ^legacy} = Codec.decode(bytes)

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v5\0" <>
                 :erlang.term_to_binary(Map.put(decoded, :backend_assignment, nil))
             )

    assert {:error, _} = Codec.decode("smolbox-record-v16\0" <> :erlang.term_to_binary(legacy))
    assert_raise ArgumentError, fn -> CodecNative.strip(native) end

    fingerprint = native.fingerprint

    assert {:ok, ^fingerprint} =
             ManagedMachineSpec.fingerprint(native.spec, String.duplicate("k", 32))
  end

  test "commands inherit native assignment evidence without acquiring a second reservation" do
    {_config, native} = fixture()
    {:ok, command} = Command.new(["/bin/true"], timeout_secs: 1)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: native.scope,
        id: "command",
        artifact: native.spec.artifact,
        profile: native.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)

    machine = %{
      native
      | state: :running,
        operation: nil,
        phase: nil,
        created_machine: observation(native),
        observed_machine: observation(native, :running, [100, 12_345])
    }

    assert {:ok, attached, record} = MachineOps.attach(machine, record, 1000)
    assert attached.reservation == machine.reservation
    assert attached.active_execution == Execution.key(record)
    assert record.backend_assignment == machine.backend_assignment

    assert :ok = Execution.validate(record)
    assert record.reservation == nil
    assert {:ok, <<"smolbox-record-v16\0", _::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)
    assert {:error, _} = Execution.transition(record, [backend_assignment: nil], 1000)
    assert {:error, _} = ManagedMachine.transition(native, [backend_assignment: nil], 1000)
  end

  test "unsupported semantics and operational resources fail before native assignment" do
    {config, native} = fixture()
    {:ok, command} = Command.new(["/bin/true"], stdin: "input", timeout_secs: 1)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: native.scope,
        id: "stdin",
        artifact: native.spec.artifact,
        profile: native.spec.profile,
        command: command
      )

    assert {:error, _} = Assignment.new(config, spec, "owned-native")
    binding = native.backend_assignment.binding

    for changed <- [
          Map.put(binding, :epoch, String.duplicate("a", 32)),
          %{binding | kind: :kubernetes},
          %{binding | generation: make_ref()},
          %{binding | target_id: "with:colon"}
        ] do
      refute Binding.valid?(changed)
    end

    refute Identity.valid?(%Identity{receipt: identity(native).receipt, pid_identity: [1, 0]})
    refute Identity.valid?(%Identity{receipt: identity(native).receipt, pid_identity: self()})
    assert {:error, _} = Codec.encode(%{native | backend_assignment: self()})
  end

  test "native terminal records retain material authority and the exclusive command slot" do
    {config, machine, record} = terminal_fixture()
    assert :ok = Execution.validate(record)
    assert record.reservation == nil
    assert machine.active_execution == Execution.key(record)
    assert {:ok, <<"smolbox-record-v17\0", payload::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 1..16,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    assert {:error, _} = Codec.encode(%{record | managed_machine: nil})
    assert {:error, _} = Codec.encode(put_in(record.backend_assignment.version, 1))
    assert {:error, _} = Codec.encode(Map.put(record, :terminal_connection, make_ref()))

    # An older approved descriptor remains unable to admit new terminal intent.
    refute Assignment.supports?(config, record.spec)
    assert {:error, _} = Assignment.qualification(config, record.spec)

    completed = %{
      record
      | state: :completed,
        evidence: :exited,
        result: %Result{exit_code: 7},
        collection: :complete
    }

    assert {:ok, released, finished} = MachineOps.finish(machine, completed, 1000)
    assert released.active_execution == nil
    assert released.reservation == machine.reservation
    assert finished.cleanup == :complete
    assert {:ok, bytes} = Codec.encode(finished)
    assert {:ok, ^finished} = Codec.decode(bytes)

    unknown = %{record | state: :unknown, evidence: :unknown}
    assert {:ok, held, uncertain} = MachineOps.finish(machine, unknown, 1000)
    assert held.state == :unknown and held.active_execution == Execution.key(record)
    assert held.reservation == machine.reservation and uncertain.result == nil
    assert {:error, _} = MachineOps.request(held, :stop, held.version, 1000)
    assert {:ok, bytes} = Codec.encode(uncertain)
    assert {:ok, ^uncertain} = Codec.decode(bytes)
  end

  test "fresh BEAM decodes native terminal intent and result with the fixed v17 vocabulary" do
    {config, _machine, record} = terminal_fixture()

    record = %{
      record
      | state: :completed,
        evidence: :exited,
        result: %Result{exit_code: 7},
        collection: :complete,
        cleanup: :complete
    }

    {:ok, bytes} = Codec.encode(record)
    path = Path.join(config.package_path, "terminal-record.etf")
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code =
      "[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do " <>
        "{:ok, %{backend_assignment: %{version: 2}, spec: %{command: %SmolBox.Terminal.Spec{}}, result: %SmolBox.Terminal.Result{exit_code: 7}}} -> IO.puts(\"fresh-native-terminal\"); _ -> System.halt(1) end"

    assert {"fresh-native-terminal\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  defp terminal_fixture do
    {config, native} = fixture()
    assignment = %{native.backend_assignment | version: 2}
    native = %{native | backend_assignment: assignment}
    created = observation(native)
    receipt = created.backend_identity.receipt

    proof = %{
      "schema" => 2,
      "revision" => 0,
      "record_sha256" => receipt["material_sha256"],
      "chain_sha256" => String.duplicate("b", 64),
      "operation_id" => nil,
      "request_sha256" => nil
    }

    created = put_in(created.backend_identity.receipt, Map.put(receipt, "material", proof))

    observed = %{
      created
      | state: :running,
        backend_identity: %{created.backend_identity | pid_identity: [100, 12_345]}
    }

    native = %{
      native
      | state: :running,
        operation: nil,
        phase: nil,
        created_machine: created,
        observed_machine: observed
    }

    {:ok, command} = Spec.new(session_ms: 1000, idle_ms: 1000)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: native.scope,
        id: "terminal",
        artifact: native.spec.artifact,
        profile: native.spec.profile,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)
    {:ok, machine, record} = MachineOps.attach(native, record, 1000)
    {config, machine, record}
  end

  test "a fresh BEAM loads only the fixed native schema vocabulary before safe decode" do
    {config, record} = fixture()

    record = %{
      record
      | created_machine: observation(record),
        state: :created,
        operation: nil,
        phase: nil
    }

    {:ok, bytes} = Codec.encode(record)
    path = Path.join(config.package_path, "record.etf")
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code =
      "[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do " <>
        "{:ok, %{backend_assignment: %{binding: %{kind: :embedded}}, created_machine: %{created_at: nil}}} " <>
        "-> IO.puts(\"fresh-native\"); _ -> System.halt(1) end"

    assert {"fresh-native\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
