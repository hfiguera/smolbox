defmodule SmolBox.Embedded.RegistryContract do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.{RegistryCredentials, Source, Validation}

  def source(%Source{kind: :registry} = source),
    do: %{
      "reference" => source.reference,
      "platform" => Source.oci_platform(source),
      "content_sha256" => source.content_sha256
    }

  def approvals(config) do
    Enum.filter(config.sources, &(&1.kind == :registry))
    |> Enum.map(fn source ->
      policy = config.registry_policy

      approval = %{
        "source" => source(source),
        "max_bytes" => policy.max_download_bytes,
        "cache_policy" => %{
          "max_bytes" => policy.max_cache_bytes,
          "max_files" => policy.max_cache_files
        }
      }

      if source.credential_ref == nil,
        do: approval,
        else:
          Map.merge(approval, %{
            "credential_ref" => source.credential_ref,
            "token_realm" => Map.fetch!(policy.token_realms, source.credential_ref)
          })
    end)
    |> Enum.uniq()
  end

  def source?(wire) do
    architecture =
      case wire do
        %{"platform" => "linux/arm64"} -> "aarch64"
        %{"platform" => "linux/amd64"} -> "x86_64"
        _ -> nil
      end

    Shape.keys?(wire, ~w(reference platform content_sha256)) and architecture != nil and
      match?(
        {:ok, _},
        Source.registry(
          id: "native-preparation",
          reference: wire["reference"],
          architecture: architecture,
          content_sha256: wire["content_sha256"]
        )
      )
  end

  def result?(wire),
    do:
      Shape.keys?(wire, ~w(result source size_bytes already_cached)) and
        wire["result"] == "prepared_artifact" and
        source?(wire["source"]) and Validation.integer?(wire["size_bytes"], 1, 34_359_738_368) and
        is_boolean(wire["already_cached"])

  def credentials?(%{"credential_ref" => reference, "identity_token" => token}),
    do: Validation.identifier?(reference) and RegistryCredentials.token?(token)

  def credentials?(wire),
    do: not Map.has_key?(wire, "credential_ref") and not Map.has_key?(wire, "identity_token")

  def sanitize(%{"operation" => "prepare_artifact"} = request),
    do: Map.delete(request, "identity_token")

  def sanitize(%{"operation" => "export_machine"} = request),
    do: Map.delete(request, "push_token")

  def sanitize(request), do: request
end
