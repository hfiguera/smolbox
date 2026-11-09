defmodule SmolBox.CheckpointArtifact do
  @moduledoc false
  alias SmolBox.{Checkpoint, Error}
  alias SmolBox.Runtime.Target

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
    host_platform = Checkpoint.host_platform(worker)
    guest_platform = guest_platform(worker)

    matches?(manifest, %{
      "mode" => "vm",
      "platform" => guest_platform,
      "host_platform" => host_platform,
      "smolvm_version" => Target.sdk_version(worker),
      "network" => false,
      "gpu" => false,
      "cuda" => false
    }) and
      matches?(checkpoint, %{
        "version" => 4,
        "runtime_abi" => "libkrun-portable-snapshot-v1",
        "device_profile" => "smolvm-basic-v1",
        "host_platform" => host_platform,
        "cpus" => profile.cpus,
        "memory_mib" => profile.memory_mb,
        "storage_gib" => profile.storage_gb,
        "overlay_gib" => profile.overlay_gb,
        "payload" => "assets"
      }) and offline_network?(checkpoint["network"]) and
      empty_fields?(manifest, ["env", "secret_refs", "cmd", "user"]) and
      manifest["entrypoint"] in [nil, [], ["/bin/true"]] and
      manifest["workdir"] in [nil, "", "/"] and
      supported_checkpoint_options?(checkpoint)
  end

  defp supported?(_, _, _), do: false

  defp supported_checkpoint_options?(checkpoint) do
    empty_fields?(checkpoint, ~w(packed_layers workload credential_ca history host_mounts)) and
      Enum.all?(~w(base cache_disk host_image), &is_nil(checkpoint[&1])) and
      checkpoint["settings"] in [nil, %{}] and
      checkpoint["disk_durability"] in [nil, "full"] and
      checkpoint["nested_virt"] in [nil, false]
  end

  defp matches?(actual, expected),
    do: Enum.all?(expected, fn {key, value} -> actual[key] == value end)

  defp empty_fields?(map, keys), do: Enum.all?(keys, &(map[&1] in [nil, [], %{}, ""]))

  defp guest_platform(%{platform: :macos, architecture: "aarch64"}), do: "linux/arm64"
  defp guest_platform(worker), do: Checkpoint.host_platform(worker)

  defp offline_network?(%{"enabled" => false} = network) do
    fields =
      ~w(ports backend dns network_name guest_subnet allowed_cidrs dns_filter_hosts credential_policy credential_placeholders mediated_egress_required)

    Enum.all?(Map.keys(network), &(&1 in ["enabled" | fields])) and
      Enum.all?(~w(ports allowed_cidrs dns_filter_hosts), &(network[&1] in [nil, []])) and
      network["credential_placeholders"] in [nil, %{}, []] and
      network["mediated_egress_required"] in [nil, false] and
      Enum.all?(~w(backend dns network_name guest_subnet credential_policy), &is_nil(network[&1]))
  end

  defp offline_network?(_), do: false
end
