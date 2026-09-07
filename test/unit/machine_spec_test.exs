defmodule SmolBox.MachineSpecTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Error, MachineSpec}

  test "machine startup remains separate from command dispatch" do
    assert {:ok, spec} = MachineSpec.new("sbx-123", "/approved/python.smolmachine")
    assert {:ok, wire} = MachineSpec.to_wire(spec)
    assert wire["entrypoint"] == ["/bin/true"]
    assert wire["cmd"] == []
    assert wire["restart"] == %{"policy" => "never"}
    assert wire["mounts"] == wire["ports"] and wire["ports"] == []
    assert wire["network"] == false
    assert wire["gpu"] == false
    assert wire["cuda"] == false
    assert wire["dockerSocket"] == false
    refute Map.has_key?(wire, "image")
    refute inspect(spec) =~ "/approved"
  end

  test "rejects unbounded resources, arbitrary image pulls, and checkpoint restoration" do
    for {name, path, options} <- [
          {"bad/name", "/x.smolmachine", []},
          {String.duplicate("a", 32), "/x.smolmachine", []},
          {"valid", "/x.smolcheckpoint", []},
          {"valid", "relative.smolmachine", []},
          {"valid", "/a/../x.smolmachine", []},
          {"valid", "/x.smolmachine", [cpus: 65]},
          {"valid", "/x.smolmachine", [memory_mb: 1]},
          {"valid", "/x.smolmachine", [overlay_gb: 65]},
          {"valid", "/x.smolmachine", [network: true]},
          {"valid", "/x.smolmachine", [cpus: 1, cpus: 2]},
          {"valid", "/x.smolmachine", %{}}
        ] do
      assert {:error, %Error{}} = MachineSpec.new(name, path, options)
    end

    assert {:error, %Error{}} = MachineSpec.validate(%{})
    assert {:ok, spec} = MachineSpec.new("valid", "/x.smolmachine")
    assert {:error, %Error{}} = MachineSpec.to_wire(%{spec | cpus: 0})
  end
end
