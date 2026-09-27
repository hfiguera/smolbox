defmodule Workspace.SavedStateFixture do
  @moduledoc "Synthetic capture metadata only; not an executable checkpoint."
  def bytes do
    manifest = %{
      "mode" => "vm",
      "platform" => "linux/amd64",
      "host_platform" => "linux/amd64",
      "smolvm_version" => "1.19.0",
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

    payload = "fixture"
    json = Jason.encode!(manifest)
    size = byte_size(payload)

    payload <>
      json <>
      <<"SMOLPACK", 1::little-32, 0::little-64, 0::little-64, size::little-64, size::little-64,
        byte_size(json)::little-64, :erlang.crc32(payload <> json)::little-32, 0::64>>
  end
end
