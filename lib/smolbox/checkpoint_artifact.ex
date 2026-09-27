defmodule SmolBox.CheckpointArtifact do
  @moduledoc false
  alias SmolBox.Error

  # Read only the bounded manifest, never unpack assets or execute artifact code.
  # The upstream restore still validates payload integrity and CPU compatibility.
  def verify(path, receipt, profile, worker) do
    case File.open(path, [:read, :binary], &inspect_file(&1, receipt, profile, worker)) do
      {:ok, :ok} ->
        :ok

      _ ->
        {:error,
         %Error{category: :unsupported_capability, operation: :checkpoint, evidence: :unknown}}
    end
  end

  defp inspect_file(io, receipt, profile, worker) do
    with {:ok, size} when size == receipt.size_bytes and size > 64 <- :file.position(io, :eof),
         {:ok, footer} <- :file.pread(io, size - 64, 64),
         {:ok, offset, length} <- manifest_location(footer, size),
         {:ok, json} <- :file.pread(io, offset, length),
         {:ok, manifest} <- Jason.decode(json),
         true <- supported?(manifest, profile, worker) do
      :ok
    else
      _ -> :unsupported
    end
  end

  defp manifest_location(
         <<"SMOLPACK", 1::little-32, 0::little-64, 0::little-64, assets::little-64,
           offset::little-64, length::little-64, _crc::little-32, 0::64>>,
         size
       )
       when assets > 0 and offset == assets and length in 1..1_048_576 and
              offset + length + 64 == size,
       do: {:ok, offset, length}

  defp manifest_location(_, _), do: :unsupported

  defp supported?(%{"checkpoint" => checkpoint} = manifest, profile, worker)
       when is_map(checkpoint) do
    platform = platform(worker)

    matches?(manifest, %{
      "mode" => "vm",
      "platform" => platform,
      "host_platform" => platform,
      "smolvm_version" => worker.runtime_version,
      "network" => false,
      "gpu" => false,
      "cuda" => false
    }) and
      matches?(checkpoint, %{
        "version" => 4,
        "runtime_abi" => "libkrun-portable-snapshot-v1",
        "device_profile" => "smolvm-basic-v1",
        "host_platform" => platform,
        "cpus" => profile.cpus,
        "memory_mib" => profile.memory_mb,
        "storage_gib" => profile.storage_gb,
        "overlay_gib" => profile.overlay_gb,
        "payload" => "assets",
        "network" => %{"enabled" => false}
      }) and empty_fields?(manifest, ["env", "secret_refs", "entrypoint", "cmd", "workdir"]) and
      empty_fields?(checkpoint, ["packed_layers", "workload", "credential_ca", "history"])
  end

  defp supported?(_, _, _), do: false

  defp matches?(actual, expected),
    do: Enum.all?(expected, fn {key, value} -> actual[key] == value end)

  defp empty_fields?(map, keys), do: Enum.all?(keys, &(map[&1] in [nil, [], %{}, ""]))

  defp platform(%{platform: :linux, architecture: "x86_64"}), do: "linux/amd64"
  defp platform(%{platform: :macos, architecture: "aarch64"}), do: "darwin/arm64"
end
