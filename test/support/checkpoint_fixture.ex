defmodule SmolBox.CheckpointFixture do
  @moduledoc false

  # Synthetic protocol metadata, not an executable VM checkpoint.
  def manifest do
    %{
      "mode" => "vm",
      "platform" => "linux/amd64",
      "host_platform" => "linux/amd64",
      "smolvm_version" => "1.22.0",
      "network" => false,
      "gpu" => false,
      "cuda" => false,
      "checkpoint" => %{
        "version" => 4,
        "runtime_abi" => "libkrun-portable-snapshot-v1",
        "device_profile" => "smolvm-basic-v1",
        "host_platform" => "linux/amd64",
        "cpus" => 1,
        "memory_mib" => 256,
        "storage_gib" => 1,
        "overlay_gib" => 1,
        "payload" => "assets",
        "network" => %{"enabled" => false}
      }
    }
  end

  def bytes(manifest \\ manifest()) do
    assets = "simulated-assets"
    json = Jason.encode!(manifest)
    size = byte_size(assets)

    assets <>
      json <>
      <<"SMOLPACK", 1::little-32, 0::little-64, 0::little-64, size::little-64, size::little-64,
        byte_size(json)::little-64, :erlang.crc32(assets <> json)::little-32, 0::64>>
  end
end
