defmodule SmolBox.SourceTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Error, Source}

  @digest String.duplicate("a", 64)
  @content String.duplicate("b", 64)
  @reference "registry.example.com/team/app@sha256:#{@digest}"

  test "local paths remain worker-specific, outside the existing immutable identity" do
    options = [id: "app", sha256: @content, architecture: "x86_64"]
    assert {:ok, first} = Source.local(options ++ [path: "/first/app.smolmachine"])
    assert {:ok, second} = Source.local(options ++ [path: "/second/app.smolmachine"])
    assert Source.artifact(first) == Source.artifact(second)

    assert Source.artifact(first) == %{
             "id" => "app",
             "sha256" => @content,
             "architecture" => "x86_64"
           }

    assert {:error, %Error{}} = Source.local(options ++ [path: "app.smolmachine"])
    assert {:error, %Error{}} = Source.local(options ++ [path: "/app.smolcheckpoint"])
  end

  test "prepared registry identity keeps manifest and content digests separate" do
    assert {:ok, source} = Source.registry(registry_options())
    assert source.sha256 == @digest
    assert source.content_sha256 == @content
    assert Source.oci_platform(source) == "linux/amd64"
    assert {:ok, ^source} = source |> Source.artifact() |> Source.from_artifact()
    refute inspect(source) =~ @reference

    for changed <- [
          %{source | sha256: @content},
          %{source | content_sha256: nil},
          %{source | path: "/app.smolmachine"},
          %{source | architecture: "amd64"},
          Map.put(source, :credential, "secret")
        ] do
      assert {:error, %Error{category: :validation}} = Source.validate(changed)
    end
  end

  test "OCI manifests have no prepared artifact digest or implicit platform conversion" do
    assert {:ok, source} = Source.oci(id: "image", reference: @reference, architecture: "aarch64")
    assert source.content_sha256 == nil
    assert Source.oci_platform(source) == "linux/arm64"
    assert {:ok, ^source} = source |> Source.artifact() |> Source.from_artifact()
    assert {:error, %Error{}} = Source.validate(%{source | content_sha256: @content})
  end

  test "only explicit canonical pinned references are accepted" do
    for location <- [
          "docker.io/library/alpine",
          "localhost:5000/team/app",
          "127.0.0.1:5001/app",
          "registry.example.com/team/app_name",
          "registry.example.com/a__b/a--b"
        ] do
      assert {:ok, _source} =
               Source.oci(
                 id: "app",
                 reference: location <> "@sha256:" <> @digest,
                 architecture: "x86_64"
               )
    end

    for reference <- [
          "alpine",
          "alpine:latest",
          "alpine@sha256:#{@digest}",
          "registry.example.com/app:latest@sha256:#{@digest}",
          "https://#{@reference}",
          "user:password@#{@reference}",
          "REGISTRY.example.com/app@sha256:#{@digest}",
          "registry.example.com/App@sha256:#{@digest}",
          "registry.example.com//app@sha256:#{@digest}",
          "registry.example.com/../app@sha256:#{@digest}",
          "registry.example.com:05000/app@sha256:#{@digest}",
          "registry.example.com:0/app@sha256:#{@digest}",
          "registry.example.com:65536/app@sha256:#{@digest}",
          "registry.example.com:abc/app@sha256:#{@digest}",
          "registry.example.com./app@sha256:#{@digest}",
          "-registry.example.com/app@sha256:#{@digest}",
          @reference <> "?token=secret",
          @reference <> "#fragment",
          @reference <> "\n",
          String.replace(@reference, @digest, String.upcase(@digest)),
          String.replace(@reference, "sha256:", "sha512:"),
          String.duplicate("x", 1025),
          nil,
          %{},
          <<255>>
        ] do
      assert {:error, %Error{category: :validation}} =
               Source.oci(id: "app", reference: reference, architecture: "x86_64")
    end
  end

  test "constructors reject secrets, mixed source options and malformed option lists" do
    for options <- [
          [],
          %{},
          [id: "app"],
          registry_options() ++ [identity_token: "secret"],
          registry_options() ++ [path: "/app.smolmachine"],
          registry_options() ++ [id: "duplicate"],
          Keyword.put(registry_options(), :content_sha256, "sha256:#{@content}")
        ] do
      assert {:error, %Error{} = error} = Source.registry(options)
      refute Exception.message(error) =~ "secret"
    end
  end

  test "durable identity decoding rejects extra fields and inconsistent digests" do
    {:ok, source} = Source.registry(registry_options())
    artifact = Source.artifact(source)

    for value <- [
          Map.put(artifact, "secret", "token"),
          Map.put(artifact, "sha256", @content),
          Map.delete(artifact, "content_sha256"),
          Map.put(artifact, "kind", "other"),
          nil
        ] do
      assert {:error, %Error{}} = Source.from_artifact(value)
    end
  end

  defp registry_options,
    do: [id: "app", reference: @reference, architecture: "x86_64", content_sha256: @content]
end
