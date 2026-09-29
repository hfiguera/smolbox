defmodule SmolBox.RegistryExport do
  @moduledoc false
  alias SmolBox.{Error, ExportDestination, ExportReceipt, ExportResult, ExportSpec, Validation}
  alias SmolBox.Transport.Req
  @manifest "application/vnd.oci.image.manifest.v1+json"
  @index "application/vnd.oci.image.index.v1+json"
  @config "application/vnd.smolmachines.machine.config.v1+json"
  @layer "application/vnd.smolmachines.smolmachine.v1"

  def vacant(spec, architecture, token) do
    with :ok <- ExportSpec.validate(spec),
         {:ok, registry} <- ExportDestination.endpoint(spec.destination, token) do
      Enum.reduce_while(ExportSpec.tags(spec, architecture), :ok, fn tag, :ok ->
        vacant_tag(registry, spec, tag)
      end)
    end
  end

  defp vacant_tag(registry, spec, tag) do
    case request(registry, spec, :head, "manifests/" <> tag, @index, :empty) do
      {:error, %Error{category: :not_found}} -> {:cont, :ok}
      {:ok, _body} -> {:halt, failure(:identity_conflict)}
      error -> {:halt, error}
    end
  end

  # Hash raw registry representations before decoding. Descriptor claims alone
  # are not proof of downloaded sidecar bytes: HEAD establishes availability;
  # the normal source preparation path verifies bytes on download, trusts cache.
  # Keep the four-argument legacy call stable; controllers always pass their worker version.
  def verify(spec, receipt, token, now, runtime_version \\ "1.19.0") do
    with :ok <- ExportSpec.validate(spec),
         :ok <- ExportReceipt.validate(receipt),
         {:ok, registry} <- ExportDestination.endpoint(spec.destination, token),
         {:ok, manifest, bytes} <-
           object(
             registry,
             spec,
             "manifests/sha256:" <> receipt.manifest_sha256,
             @manifest,
             receipt.manifest_sha256
           ),
         {:ok, config, layer} <- descriptors(manifest, receipt),
         {:ok, metadata, config_bytes} <-
           object(
             registry,
             spec,
             "blobs/" <> config["digest"],
             "application/octet-stream",
             String.replace_prefix(config["digest"], "sha256:", "")
           ),
         true <- byte_size(config_bytes) == config["size"],
         true <-
           metadata["platform"] == receipt.platform and metadata["mode"] in ["vm", "container"],
         :ok <- published_tags(registry, spec, receipt, byte_size(bytes)),
         {:ok, ""} <- request(registry, spec, :head, "blobs/" <> layer["digest"], @layer, :empty),
         result = %ExportResult{
           reference:
             ExportDestination.reference(spec.destination, "sha256:" <> receipt.manifest_sha256),
           manifest_sha256: receipt.manifest_sha256,
           config_sha256: String.replace_prefix(config["digest"], "sha256:", ""),
           content_sha256: String.replace_prefix(layer["digest"], "sha256:", ""),
           size_bytes: receipt.size_bytes,
           architecture: architecture(receipt.platform),
           platform: receipt.platform,
           verified_at_ms: now,
           runtime_version: runtime_version
         },
         :ok <- ExportResult.validate(result) do
      {:ok, result}
    else
      {:error, _error} = error -> error
      _invalid -> failure(:protocol)
    end
  end

  defp descriptors(
         %{
           "schemaVersion" => 2,
           "mediaType" => @manifest,
           "artifactType" => @layer,
           "config" => config,
           "layers" => [layer]
         },
         receipt
       ) do
    if descriptor?(config, @config) and descriptor?(layer, @layer) and
         layer["size"] == receipt.size_bytes, do: {:ok, config, layer}, else: failure(:protocol)
  end

  defp descriptors(_manifest, _receipt), do: failure(:protocol)

  defp descriptor?(%{"mediaType" => type, "digest" => "sha256:" <> digest, "size" => size}, type),
    do: Validation.digest?(digest) and Validation.integer?(size, 1, 9_223_372_036_854_775_807)

  defp descriptor?(_value, _type), do: false

  defp published_tags(registry, spec, receipt, size) do
    [tag, platform_tag] = ExportSpec.tags(spec, architecture(receipt.platform))

    with {:ok, _manifest, _bytes} <-
           object(
             registry,
             spec,
             "manifests/" <> platform_tag,
             @manifest,
             receipt.manifest_sha256
           ),
         {:ok, bytes} <- request(registry, spec, :get, "manifests/" <> tag, @index, :buffer),
         {:ok, %{"schemaVersion" => 2, "mediaType" => @index, "manifests" => [entry]}} <-
           Jason.decode(bytes),
         true <- descriptor?(entry, @manifest),
         true <- entry["digest"] == "sha256:" <> receipt.manifest_sha256 and entry["size"] == size,
         true <-
           entry["platform"] == %{
             "os" => "linux",
             "architecture" => String.replace_prefix(receipt.platform, "linux/", "")
           } do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> failure(:protocol)
    end
  end

  defp object(registry, spec, suffix, media, digest) do
    with {:ok, bytes} <- request(registry, spec, :get, suffix, media, :buffer),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
         {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value, bytes}
    else
      {:error, %Error{}} = error -> error
      _invalid -> failure(:protocol)
    end
  end

  defp request(registry, spec, method, suffix, accept, mode) do
    request = %{
      method: method,
      path: "/v2/" <> spec.destination.repository <> "/" <> suffix,
      body: "",
      content_type: "application/json",
      accept: accept,
      mode: mode,
      max_bytes: 1_048_576
    }

    case Req.request(registry, request) do
      {:ok, body} -> {:ok, body}
      {:error, %Error{category: category}} -> failure(category)
    end
  end

  defp architecture("linux/amd64"), do: "x86_64"
  defp architecture("linux/arm64"), do: "aarch64"

  defp failure(category),
    do: {:error, %Error{category: category, operation: :export, evidence: :unknown}}
end
