defmodule SmolBox.CheckpointArtifactTest do
  use ExUnit.Case, async: true
  alias SmolBox.{CheckpointArtifact, CheckpointFixture, Profile}

  test "bounded metadata inspection rejects malformed containers without adopting bytes" do
    path =
      Path.join(System.tmp_dir!(), "checkpoint-metadata-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    {:ok, profile} = Profile.new("test")
    worker = %{platform: :linux, architecture: "x86_64", runtime_version: "1.19.0"}
    valid = CheckpointFixture.bytes()

    verify = fn bytes, size ->
      File.write!(path, bytes)
      CheckpointArtifact.verify(path, %{size_bytes: size}, profile, worker)
    end

    assert :ok = verify.(valid, byte_size(valid))

    invalid = [
      <<>>,
      valid <> "trailing",
      binary_part(valid, 0, byte_size(valid) - 1),
      "x" <>
        <<"SMOLPACK", 1::little-32, 0::little-64, 0::little-64, 1::little-64, 1::little-64,
          1_048_577::little-64, 0::little-32, 0::64>>,
      CheckpointFixture.bytes(%{"checkpoint" => "invalid"}),
      CheckpointFixture.bytes(%{"mode" => "vm"})
    ]

    for bytes <- invalid do
      assert {:error, %{evidence: :unknown}} = verify.(bytes, byte_size(bytes))
    end

    assert {:error, _} = verify.(valid, byte_size(valid) + 1)
    File.rm!(path)
    assert {:error, _} = CheckpointArtifact.verify(path, %{size_bytes: 1024}, profile, worker)
  end
end
