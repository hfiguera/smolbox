defmodule SmolBox.Embedded.ExportContract do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.{ExportDestination, RegistryCredentials, Source, Validation}

  @request ~w(request_sha256 destination_id destination_sha256 tag max_artifact_bytes max_staging_bytes)
  @identity ~w(destination_id destination_sha256 registry repository tag platform_tag platform content_sha256 size_bytes config_sha256 manifest_sha256 index_sha256)
  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256 material)
  @material ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)
  @limits %{
    "staging_bytes" => 549_755_813_888,
    "metadata_bytes" => 1_048_576,
    "upload_chunk_bytes" => 1_048_576,
    "registry_requests" => 1_048_576,
    "record_bytes" => 16_384,
    "records" => 256,
    "asset_file_bytes" => 2_147_483_648,
    "asset_total_bytes" => 4_294_967_296,
    "control_metadata_bytes" => 262_144,
    "observation_metadata_bytes" => 131_072,
    "retirement_metadata_bytes" => 33_554_432
  }
  def limits, do: @limits

  def tag?(value),
    do:
      is_binary(value) and byte_size(value) in 1..100 and
        Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/, value)

  def request?(value),
    do:
      Shape.keys?(value, @request) and Validation.digest?(value["request_sha256"]) and
        Shape.id?(value["destination_id"]) and Validation.digest?(value["destination_sha256"]) and
        tag?(value["tag"]) and
        Validation.integer?(value["max_artifact_bytes"], 1, @limits["staging_bytes"]) and
        Validation.integer?(
          value["max_staging_bytes"],
          value["max_artifact_bytes"] + 1,
          @limits["staging_bytes"]
        )

  def identity?(value) do
    Shape.keys?(value, @identity) and Shape.id?(value["destination_id"]) and
      Enum.all?(
        ~w(destination_sha256 content_sha256 config_sha256 manifest_sha256 index_sha256),
        &Validation.digest?(value[&1])
      ) and
      Validation.text?(value["registry"], 260) and Validation.text?(value["repository"], 256) and
      tag?(value["tag"]) and value["platform"] in ~w(linux/amd64 linux/arm64) and
      value["platform_tag"] == value["tag"] <> "-" <> String.replace(value["platform"], "/", "-") and
      Validation.integer?(value["size_bytes"], 1, @limits["staging_bytes"]) and
      match?(
        {:ok, _},
        Source.registry(
          id: "native-export",
          reference:
            value["registry"] <>
              "/" <> value["repository"] <> "@sha256:" <> value["manifest_sha256"],
          content_sha256: value["content_sha256"],
          architecture: if(value["platform"] == "linux/amd64", do: "x86_64", else: "aarch64")
        )
      )
  end

  def proof_digest(source, id, request, identity) do
    source = source |> Map.update!("material", &ordered(&1, @material)) |> ordered(@receipt)
    digest(["smolbox-export-publication-v1", source, id, request, ordered(identity, @identity)])
  end

  def approved_cached?(catalog, %{"operation" => name, "request" => request})
      when name in ~w(qualify_export admit_export export_machine),
      do:
        Enum.any?(
          catalog,
          &(&1["id"] == request["destination_id"] and
              &1["destination_sha256"] == request["destination_sha256"] and
              request["max_artifact_bytes"] <= &1["max_artifact_bytes"] and
              request["max_staging_bytes"] <= &1["max_staging_bytes"])
        )

  def approved_cached?(_catalog, _operation), do: true
  def token?(token), do: RegistryCredentials.token?(token)

  def approvals(config) do
    Enum.map(config.export_destinations, fn destination ->
      :ok = ExportDestination.validate(destination)
      {path, ca_hash} = certificate(destination.ca_cert_file)
      maximum = min(destination.resources.disk_gb * 1_073_741_824, @limits["staging_bytes"])

      %{
        "id" => destination.id,
        "registry" => destination.registry,
        "repository" => destination.repository,
        "credential_ref" => destination.credential_ref,
        "immutable_tags" => destination.immutable_tags,
        "allow_insecure_loopback" => destination.allow_insecure_loopback,
        "ca_cert_file" => path,
        "ca_certificate_sha256" => ca_hash,
        "destination_sha256" =>
          digest([
            "smolbox-export-destination-v1",
            destination.id,
            destination.registry,
            destination.repository,
            destination.immutable_tags,
            destination.allow_insecure_loopback,
            ca_hash
          ]),
        "max_artifact_bytes" => maximum,
        "max_staging_bytes" => maximum,
        "conversion_resources" =>
          Map.new(destination.resources, fn {key, value} -> {Atom.to_string(key), value} end)
      }
    end)
  end

  defp certificate(nil), do: {nil, nil}

  defp certificate(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size in 1..262_144,
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, bytes} <- :file.read(file, 262_145),
             true <- byte_size(bytes) == size,
             {:ok, %{type: :regular, size: ^size}} <- File.lstat(path),
             do: {path, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)},
             else: (_ -> raise ArgumentError, "invalid export trust input")
      after
        File.close(file)
      end
    else
      _ -> raise ArgumentError, "invalid export trust input"
    end
  end

  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}

  defp digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
