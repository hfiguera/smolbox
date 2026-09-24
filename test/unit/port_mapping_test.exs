defmodule SmolBox.PortMappingTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Machine, MachineSpec, ManagedMachineSpec, PortMapping}
  alias SmolBox.Store.{Codec, CodecExecution, CodecFiles, Contract, MachineContract, Memory}

  test "fixed TCP mappings have bounded exact fields and canonical host identity" do
    {:ok, first} = PortMapping.new(host: 8080, guest: 80)
    {:ok, second} = PortMapping.new(host: 8081, guest: 80)
    assert {:ok, [^first, ^second]} = PortMapping.normalize([second, first])
    assert {:error, _} = PortMapping.normalize([first, %{first | guest: 81}])
    assert {:error, _} = PortMapping.normalize(List.duplicate(first, 33))

    for options <- [
          [host: 0, guest: 80],
          [host: 8080, guest: 65_536],
          [host: "8080", guest: 80],
          [host: 8080, guest: 80, protocol: :udp],
          [host: 8080, guest: 80, address: "127.0.0.1"],
          [host: 8080, host: 8081, guest: 80]
        ] do
      assert {:error, _} = PortMapping.new(options)
    end

    refute PortMapping.valid?(Map.put(first, :surprise, true))
    assert {:error, _} = PortMapping.from_wire([%{"host" => 8080, "guest" => 80, "udp" => true}])
  end

  test "inbound-only creation explicitly denies outbound and decoding verifies that policy" do
    {:ok, mapping} = PortMapping.new(host: 18_080, guest: 8000)
    {:ok, spec} = MachineSpec.new("http", "/approved/python.smolmachine", ports: [mapping])
    {:ok, wire} = MachineSpec.to_wire(spec)
    assert wire["ports"] == [%{"host" => 18_080, "guest" => 8000}]
    assert wire["network"] == false
    assert wire["networkBackend"] == "virtio-net"
    assert wire["allowedHosts"] == [] and wire["allowedCidrs"] == []
    observed = Map.merge(wire, %{"state" => "created", "createdAt" => 1})
    assert {:ok, machine} = Machine.from_wire(observed)
    assert machine.ports == [mapping] and machine.network == :offline

    for bad <- [
          Map.delete(observed, "allowedHosts"),
          Map.delete(observed, "allowedCidrs"),
          Map.put(observed, "networkBackend", "tsi"),
          Map.put(observed, "network", true),
          Map.put(observed, "mounts", [%{}])
        ] do
      assert {:error, _} = Machine.from_wire(bad)
    end

    assert {:error, _} =
             MachineSpec.new("idle", "/approved/idle.smolcheckpoint",
               source: :checkpoint,
               ports: [mapping]
             )

    refute Machine.same_incarnation?(machine, %{machine | ports: []})
  end

  test "mapping order deduplicates but changed endpoints conflict without changing no-port identity" do
    original = MachineContract.record().spec
    options = Map.to_list(Map.from_struct(original))
    {:ok, first} = PortMapping.new(host: 8080, guest: 80)
    {:ok, second} = PortMapping.new(host: 8081, guest: 81)
    {:ok, a} = ManagedMachineSpec.new(Keyword.put(options, :ports, [first, second]))
    {:ok, b} = ManagedMachineSpec.new(Keyword.put(options, :ports, [second, first]))
    key = :binary.copy(<<1>>, 32)
    assert ManagedMachineSpec.fingerprint(a, key) == ManagedMachineSpec.fingerprint(b, key)
    refute ManagedMachineSpec.fingerprint(a, key) == ManagedMachineSpec.fingerprint(original, key)
    assert {:ok, _execution} = ManagedMachineSpec.execution_spec(a)
  end

  test "v4 machines migrate only absent port fields and v5 cannot masquerade as v4" do
    record = MachineContract.record()

    legacy =
      record
      |> CodecFiles.strip()
      |> Map.delete(:reserved_ports)
      |> Map.update!(:spec, &Map.drop(&1, [:ports, :workload]))

    bytes = "smolbox-record-v4\0" <> :erlang.term_to_binary(legacy)
    assert {:ok, ^record} = Codec.decode(bytes)
    assert {:ok, <<"smolbox-record-v5\0", payload::binary>>} = Codec.encode(record)
    assert {:error, _} = Codec.decode("smolbox-record-v4\0" <> payload)
    assert {:error, _} = Codec.decode("smolbox-record-v5\0" <> :erlang.term_to_binary(legacy))
  end

  test "v4 assigned machines and commands preserve ownership evidence and no-port identity" do
    store = start_supervised!(Memory)
    record = MachineContract.running(Memory, store)

    old =
      record
      |> CodecFiles.strip()
      |> Map.delete(:reserved_ports)
      |> Map.update!(:spec, &Map.drop(&1, [:ports, :workload]))
      |> Map.update!(:created_machine, &Map.delete(&1, :ports))
      |> Map.update!(:observed_machine, &Map.delete(&1, :ports))

    assert {:ok, ^record} = Codec.decode("smolbox-record-v4\0" <> :erlang.term_to_binary(old))

    {:ok, command} =
      Memory.machine(store, :submit, [{record.scope, record.id}, Contract.record(), 10, 1100])

    old_command =
      command
      |> Map.update!(:created_machine, &Map.delete(&1, :ports))
      |> CodecExecution.strip()
      |> CodecFiles.strip()

    assert {:ok, ^command} =
             Codec.decode("smolbox-record-v4\0" <> :erlang.term_to_binary(old_command))

    {:ok, encoded} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(encoded)

    {:ok, spec} = ManagedMachineSpec.execution_spec(record.spec)
    key = :binary.copy(<<1>>, 32)
    {:ok, digest} = SmolBox.ExecutionSpec.fingerprint(spec, key)

    legacy_digest =
      :crypto.mac(:hmac, :sha256, key, "smolbox-managed-machine-v1:" <> digest)
      |> Base.encode16(case: :lower)

    assert ManagedMachineSpec.fingerprint(record.spec, key) == {:ok, legacy_digest}
  end
end
