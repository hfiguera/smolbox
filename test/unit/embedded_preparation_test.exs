defmodule SmolBox.EmbeddedPreparationTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ArtifactPreparation, Error, Source}
  alias SmolBox.Backend.{Budget, Embedded, EmbeddedOperation, EmbeddedPreparation}
  alias SmolBox.Embedded.RegistryContract

  defp source do
    {:ok, source} =
      Source.registry(
        id: "prepared",
        reference: "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
        architecture: "aarch64",
        content_sha256: String.duplicate("b", 64)
      )

    source
  end

  defp budget,
    do: %Budget{timeout_ms: 1000, max_request_bytes: 16_384, max_response_bytes: 32_768}

  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  test "prepared wire evidence translates exact distinct manifest/content identity" do
    source = source()
    request = %{"operation" => "prepare_artifact", "source" => RegistryContract.source(source)}

    outcome = %{
      "result" => "prepared_artifact",
      "source" => request["source"],
      "size_bytes" => 123,
      "already_cached" => false
    }

    assert {:ok, %ArtifactPreparation{} = prepared} =
             EmbeddedPreparation.decode(nil, source, request, {:ok, outcome, empty(), nil})

    assert prepared.manifest_sha256 == source.sha256
    assert prepared.content_sha256 == source.content_sha256
    assert prepared.size_bytes == 123 and prepared.already_cached == false
    assert ArtifactPreparation.matches?(prepared, Source.artifact(source))
    crossed = put_in(outcome, ["source", "content_sha256"], String.duplicate("c", 64))

    assert {:error, %Error{category: :protocol, evidence: :dispatch_uncertain}} =
             EmbeddedPreparation.decode(nil, source, request, {:ok, crossed, empty(), nil})

    assert {:error, _} =
             EmbeddedPreparation.decode(
               nil,
               source,
               request,
               {:ok, outcome, %{empty() | file: "unexpected"}, nil}
             )
  end

  test "native errors keep safe category and dispatch evidence" do
    outcome = %{"result" => "error", "code" => "unsupported", "dispatch" => "not_dispatched"}

    assert {:error,
            %Error{
              category: :unsupported_capability,
              operation: :prepare_artifact,
              evidence: :not_dispatched
            }} = EmbeddedPreparation.decode(nil, source(), %{}, {:ok, outcome, empty(), nil})

    assert {:error, %Error{operation: :prepare_artifact}} =
             EmbeddedPreparation.decode(
               nil,
               source(),
               %{},
               {:error,
                %Error{category: :expired, operation: :port, evidence: :dispatch_uncertain}}
             )
  end

  test "invalid options and current unapproved config cannot create preparation requests" do
    assert Embedded.supports_operation?(nil, :prepare_artifact)
    refute Embedded.supports_operation?(%{}, :prepare_artifact)

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             EmbeddedPreparation.build(nil, [source()], budget())

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             EmbeddedPreparation.build(nil, [source(), [identity_token: "private"]], budget())
  end

  test "credential rotation changes transient payload but not source identity" do
    source = %{source() | credential_ref: "tenant"}

    for token <- ["token-one", "token-two"] do
      assert {:ok, %{"credential_ref" => "tenant", "identity_token" => ^token}} =
               EmbeddedPreparation.credentials(source, identity_token: token)
    end

    assert {:error, %Error{category: :authentication}} =
             EmbeddedPreparation.credentials(source, [])

    assert {:error, _} = EmbeddedPreparation.credentials(source, identity_token: "bad token")
  end

  test "prepared create request is bound to original source and positive observation size" do
    source = source()

    {:ok, prepared} =
      ArtifactPreparation.from_wire(source, %{
        "digest" => "sha256:" <> source.content_sha256,
        "sizeBytes" => 123,
        "alreadyCached" => true
      })

    create = %{"source" => Source.artifact(source)}
    request = %{"operation" => "create_registry_prepared", "create" => create}
    assert {:ok, wire} = EmbeddedOperation.prepared_request(request, prepared)
    assert wire["size_bytes"] == 123 and wire["create"] == create
    assert {:error, _} = EmbeddedOperation.prepared_request(request, %{prepared | size_bytes: 0})

    assert {:error, _} =
             EmbeddedOperation.prepared_request(request, %{
               prepared
               | manifest_sha256: String.duplicate("c", 64)
             })

    assert {:error, _} =
             EmbeddedOperation.prepared_request(
               %{request | "operation" => "create_oci"},
               prepared
             )

    assert Embedded.supports_operation?(nil, :create_prepared)
    refute Embedded.supports_operation?(%{}, :create_prepared)
  end
end
