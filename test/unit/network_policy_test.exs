defmodule SmolBox.NetworkPolicyTest do
  use ExUnit.Case, async: true

  alias SmolBox.{ExecutionSpec, Machine, MachineSpec, NetworkPolicy, Profile}
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.{Codec, Contract}

  test "bounded explicit policies canonicalize order and reject unrestricted or ambiguous inputs" do
    assert {:ok, policy} =
             NetworkPolicy.new(
               hosts: ["b.example.com", "a.example.com"],
               cidrs: ["2001:db8::/32", "203.0.113.0/24"]
             )

    assert policy.hosts == ["a.example.com", "b.example.com"]
    assert NetworkPolicy.valid?(policy)
    assert NetworkPolicy.valid?(:offline)
    refute NetworkPolicy.valid?(true)
    refute NetworkPolicy.valid?(Map.put(policy, :unknown, true))
    refute NetworkPolicy.valid?(%{policy | hosts: Enum.reverse(policy.hosts)})

    for options <- [
          [],
          [hosts: []],
          [hosts: ["*"]],
          [hosts: ["*.example.com"]],
          [hosts: ["https://example.com"]],
          [hosts: ["Example.com"]],
          [hosts: ["example.com."]],
          [hosts: ["localhost"]],
          [hosts: ["127.0.0.1"]],
          [hosts: ["a..com"]],
          [hosts: [String.duplicate("x", 64) <> ".com"]],
          [hosts: ["a.com", "a.com"]],
          [cidrs: ["0.0.0.0/0"]],
          [cidrs: ["::/0"]],
          [cidrs: ["10.0.0.1/24"]],
          [cidrs: ["10.0.0.0/33"]],
          [cidrs: ["10.0.0.0/08"]],
          [cidrs: ["bad"]],
          [cidrs: [<<255>> <> "/24"]],
          [cidrs: ["2001:DB8::/32"]],
          [cidrs: ["2001:db8::1/32"]],
          [cidrs: [nil]],
          [hosts: nil],
          [hosts: Enum.map(1..33, &"h#{&1}.example.com")],
          [hosts: ["a.com"], extra: true],
          [hosts: ["a.com"], hosts: ["b.com"]],
          %{}
        ] do
      assert {:error, _} = NetworkPolicy.new(options)
    end
  end

  test "policy survives profile conversion, strict wire observations and incarnation comparisons" do
    {:ok, policy} = NetworkPolicy.new(hosts: ["api.example.com"])
    {:ok, profile} = Profile.new("api-v1", network: policy)
    {:ok, spec} = Profile.machine(profile, "fixture", "/approved/python.smolmachine")
    assert {:ok, wire} = MachineSpec.to_wire(spec)
    assert wire["allowedHosts"] == ["api.example.com"]
    assert wire["allowedCidrs"] == []
    assert wire["networkBackend"] == "virtio-net"
    assert wire["ports"] == wire["mounts"] and wire["ports"] == []
    fixture = File.read!("test/fixtures/wire/created.json") |> Jason.decode!()
    response = Map.merge(fixture, NetworkPolicy.to_wire(policy))
    assert {:ok, machine} = Machine.from_wire(response)
    assert machine.network == policy
    assert Machine.same_incarnation?(machine, %{machine | state: :running})
    refute Machine.same_incarnation?(machine, %{machine | network: :offline})

    for changed <- [
          Map.delete(response, "allowedHosts"),
          Map.delete(response, "allowedCidrs"),
          Map.put(response, "allowedHosts", []),
          Map.put(response, "networkBackend", "tsi"),
          Map.put(response, "network", false)
        ] do
      assert {:error, _} = Machine.from_wire(changed)
    end
  end

  test "policy is durable identity and must be approved on a supported worker" do
    record = Contract.record()
    {:ok, policy} = NetworkPolicy.new(cidrs: ["203.0.113.1/32"])
    profile = %{record.spec.profile | network: policy}
    spec = %{record.spec | profile: profile}
    assert {:ok, offline_id} = ExecutionSpec.fingerprint(record.spec, :binary.copy(<<1>>, 32))
    assert {:ok, network_id} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    refute offline_id == network_id

    worker = %WorkerConfig{
      client: nil,
      platform: :linux,
      architecture: spec.artifact["architecture"],
      profiles: [profile],
      artifacts: [Map.put(spec.artifact, "path", "/approved/a.smolmachine")],
      allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256},
      capacity: Contract.capacity()
    }

    assert WorkerConfig.supports?(worker, spec)
    refute WorkerConfig.supports?(%{worker | runtime_version: "1.14.6"}, spec)
    refute WorkerConfig.supports?(%{worker | profiles: [record.spec.profile]}, spec)
    network_record = %{record | spec: spec, fingerprint: network_id}
    assert {:ok, bytes} = Codec.encode(network_record)
    assert {:ok, ^network_record} = Codec.decode(bytes)
  end

  test "legacy offline records gain only offline defaults and retain their fingerprint" do
    record = Contract.record()

    assert record.fingerprint ==
             "8c15bdeb56a1a710e230213b616051a87231d7f92c0a1d7620f66f326e9aa3a6"

    legacy = %{record | spec: %{record.spec | profile: Map.delete(record.spec.profile, :network)}}
    bytes = "smolbox-record-v1\0" <> :erlang.term_to_binary(legacy)
    assert {:ok, ^record} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode(bytes <> "extra")
    assert {:error, _} = Codec.decode("smolbox-record-v1\0" <> :erlang.term_to_binary(record))
    assert {:error, _} = Codec.decode("smolbox-record-v2\0" <> :erlang.term_to_binary(legacy))
    forged = %{legacy | created_machine: %{__struct__: Machine, network: :offline}}
    assert {:error, _} = Codec.decode("smolbox-record-v1\0" <> :erlang.term_to_binary(forged))
  end

  test "legacy creation evidence migrates and a changed machine policy cannot be persisted" do
    record = Contract.record()

    machine = %Machine{
      name: "owned",
      state: :created,
      created_at: 1,
      cpus: 1,
      memory_mb: 256,
      storage_gb: 1,
      overlay_gb: 1
    }

    record = %{
      record
      | worker_id: "worker",
        worker_generation: 1,
        machine_name: machine.name,
        created_machine: machine,
        reservation: Contract.capacity()
    }

    legacy = %{
      record
      | spec: %{record.spec | profile: Map.delete(record.spec.profile, :network)},
        created_machine: Map.delete(machine, :network)
    }

    assert {:ok, ^record} = Codec.decode("smolbox-record-v1\0" <> :erlang.term_to_binary(legacy))
    {:ok, policy} = NetworkPolicy.new(hosts: ["api.example.com"])
    assert {:error, _} = Codec.encode(%{record | created_machine: %{machine | network: policy}})
  end
end
