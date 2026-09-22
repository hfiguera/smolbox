defmodule SmolBox.CheckpointTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Checkpoint, ExecutionSpec, Files, MachineSpec, NetworkPolicy, Profile}
  alias SmolBox.Store.{Codec, Contract}

  defp approval(options \\ []) do
    {:ok, profile} = Profile.new("idle-v1")

    Checkpoint.new(
      Keyword.merge(
        [
          id: "idle",
          sha256: Files.sha256("checkpoint"),
          architecture: "x86_64",
          platform: :linux,
          path: "/approved/idle.smolcheckpoint",
          profile: profile
        ],
        options
      )
    )
  end

  test "approval rejects incompatible, networked, resumable and malformed sources" do
    {:ok, policy} = NetworkPolicy.new(hosts: ["example.com"])
    {:ok, online} = Profile.new("online", network: policy)

    for options <- [
          [profile: online],
          [resume: :running],
          [runtime_version: "1.16.0"],
          [architecture: "aarch64"],
          [platform: :windows],
          [path: "/tmp/a.smolmachine"],
          [path: "/tmp/../a.smolcheckpoint"],
          [sha256: "bad"],
          [profile: %{}],
          [unknown: true]
        ] do
      assert {:error, _} = approval(options)
    end

    for version <- ["1.16.1", "1.17.0"] do
      assert {:ok, %{runtime_version: ^version}} = approval(runtime_version: version)
    end

    assert {:error, _} = Checkpoint.new([])
    assert {:error, _} = Checkpoint.validate(%{})
    assert {:ok, _} = approval(platform: :macos, architecture: "aarch64")
  end

  test "checkpoint request preserves captured topology without pretending to override entrypoint" do
    {:ok, checkpoint} = approval()
    {:ok, machine} = Checkpoint.machine(checkpoint, "child")
    {:ok, wire} = MachineSpec.to_wire(machine)
    assert wire["from"] == "/approved/idle.smolcheckpoint"
    assert wire["network"] == false
    refute Enum.any?(~w(storageGb overlayGb entrypoint cmd), &Map.has_key?(wire, &1))
    assert wire["cpus"] == 1 and wire["memoryMb"] == 256
    assert {:error, _} = MachineSpec.new("child", checkpoint.path)
    assert {:error, _} = MachineSpec.validate(%{machine | source: :anything})
  end

  test "checkpoint identity cannot alias an image and schema v3 cannot masquerade as v2" do
    {:ok, checkpoint} = approval()
    image = Contract.record()
    spec = %{image.spec | artifact: Checkpoint.artifact(checkpoint)}
    assert :ok = ExecutionSpec.validate(spec)
    key = :binary.copy(<<1>>, 32)
    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, key)

    {:ok, image_fingerprint} =
      ExecutionSpec.fingerprint(%{spec | artifact: Map.delete(spec.artifact, "kind")}, key)

    refute fingerprint == image_fingerprint
    record = %{image | spec: spec, fingerprint: fingerprint}
    assert {:ok, <<"smolbox-record-v3", 0, _::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    assert {:error, _} =
             Codec.decode(String.replace_prefix(bytes, "smolbox-record-v3", "smolbox-record-v2"))

    assert {:ok, <<"smolbox-record-v2", 0, _::binary>> = legacy} = Codec.encode(image)
    assert {:ok, ^image} = Codec.decode(legacy)

    assert {:error, _} =
             Codec.decode(String.replace_prefix(legacy, "smolbox-record-v2", "smolbox-record-v3"))

    assert {:error, _} =
             ExecutionSpec.validate(%{spec | artifact: Map.put(spec.artifact, "kind", "unknown")})
  end
end
