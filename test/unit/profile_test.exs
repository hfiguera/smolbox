defmodule SmolBox.ProfileTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Error, MachineSpec, Profile}

  test "policy conversion remains offline and neutral" do
    assert {:ok, profile} = Profile.new("offline-v1")
    assert {:ok, machine} = Profile.machine(profile, "sbx1", "/approved/python.smolmachine")
    assert {:ok, wire} = MachineSpec.to_wire(machine)
    assert wire["network"] == false
    assert wire["entrypoint"] == ["/bin/true"]
    assert wire["restart"] == %{"policy" => "never"}
    assert wire["mounts"] == []
    assert wire["ports"] == []
  end

  test "unverified hard controls cannot masquerade as supported configuration" do
    for key <- [
          :network,
          :mounts,
          :ports,
          :gpu,
          :cpu_time_ms,
          :host_rss_mb,
          :process_limit,
          :host_disk_bytes,
          :restart,
          :background
        ] do
      assert {:error, %Error{category: :unsupported_capability}} = Profile.new("p", [{key, 1}])
    end

    for options <- [
          [],
          [cpus: 0],
          [memory_mb: 1],
          [execution_ms: 1],
          [host_overhead_mb: 1],
          [unknown: 1],
          [cpus: 1, cpus: 2],
          %{}
        ] do
      id = if options == [], do: "invalid/id", else: "p"
      assert {:error, %Error{category: :validation}} = Profile.new(id, options)
    end

    assert {:error, _} = Profile.validate(nil)
    assert {:error, _} = Profile.machine(nil, "x", "/x.smolmachine")
  end
end
