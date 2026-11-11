defmodule SmolBox.Embedded.CreationPayload do
  @moduledoc false
  alias SmolBox.Embedded.{Config, CreationFeatures, JSON}
  import SmolBox.Embedded.PayloadFields, only: [strings: 1, string: 1, optional: 1]
  @maximum 655_360
  @chunk 65_536

  def limits,
    do: %{"schema" => 1, "payload_bytes" => @maximum, "chunks" => 10, "chunk_bytes" => @chunk}

  def pack(operation, config) do
    case Config.sdk_identity(config) do
      %{"feature_versions" => %{"compact_creation" => 1}} -> pack_operation(operation)
      _legacy -> {:ok, operation}
    end
  end

  def encode(%{"branch_https" => true}), do: :error

  def encode(features) do
    if CreationFeatures.valid?(features) do
      network = features["network"]

      bytes =
        IO.iodata_to_binary([
          "SBCF",
          <<1>>,
          flag(network["enabled"]),
          strings(network["hosts"]),
          strings(network["cidrs"]),
          <<length(features["ports"])::unsigned-big-16>>,
          Enum.map(features["ports"], fn mapping ->
            <<mapping["host"]::unsigned-big-16, mapping["guest"]::unsigned-big-16>>
          end),
          workload(features["workload"])
        ])

      if byte_size(bytes) <= @maximum,
        do: {:ok, %{"schema" => 1, "chunks" => chunks(bytes)}},
        else: :error
    else
      :error
    end
  end

  defp pack_operation(%{"operation" => name, "create" => create} = operation)
       when name in ~w(create inspect_creation create_oci inspect_oci_creation create_registry_prepared inspect_registry_creation) do
    with {:ok, value} <- pack_fields(create), do: {:ok, %{operation | "create" => value}}
  end

  defp pack_operation(%{"operation" => name} = operation)
       when name in ~w(qualify_creation qualify_oci_creation qualify_registry_creation),
       do: pack_fields(operation)

  defp pack_operation(operation), do: {:ok, operation}

  defp pack_fields(%{"features" => %{"workload" => workload} = features} = fields)
       when not is_nil(workload) do
    case JSON.encode(features) do
      {:ok, encoded} when byte_size(encoded) <= 262_144 ->
        {:ok, fields}

      _large ->
        with {:ok, payload} <- encode(features),
             do: {:ok, fields |> Map.delete("features") |> Map.put("features_payload", payload)}
    end
  end

  defp pack_fields(fields), do: {:ok, fields}

  defp flag(true), do: <<1>>
  defp flag(false), do: <<0>>
  defp workload(nil), do: <<0>>

  defp workload(value) do
    env = Enum.sort(value["env"])

    [
      <<1>>,
      strings(value["entrypoint"]),
      strings(value["cmd"]),
      <<length(env)::unsigned-big-16>>,
      Enum.map(env, fn {key, value} -> [string(key), string(value)] end),
      optional(value["workdir"])
    ]
  end

  defp chunks(<<>>), do: []
  defp chunks(bytes) when byte_size(bytes) <= @chunk, do: [Base.encode64(bytes)]

  defp chunks(<<head::binary-size(@chunk), rest::binary>>),
    do: [Base.encode64(head) | chunks(rest)]
end
