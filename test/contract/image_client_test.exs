defmodule SmolBox.ImageClientTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Client, Error, Image, ImageInventory, Source, TestPeer, Worker}

  @manifest String.duplicate("a", 64)
  @config String.duplicate("b", 64)
  @reference "registry.example.com/team/app@sha256:" <> @manifest

  test "empty lists cannot claim a stopped machine has no images" do
    client =
      client(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v1/machines/fixture/images"
        TestPeer.json(conn, %{"images" => []})
      end)

    assert {:ok, %ImageInventory{images: [], availability: :empty_or_unavailable}} =
             Client.list_images(client, "fixture")
  end

  test "lists distinguish configuration digests from imported packed images" do
    client =
      client(fn conn ->
        TestPeer.json(conn, %{"images" => [image(), Map.put(image(), "digest", "packed")]})
      end)

    assert {:ok, %ImageInventory{images: [first, second], availability: :observed}} =
             Client.list_images(client, "fixture")

    assert first.digest_kind == :configuration
    assert first.digest == "sha256:" <> @config
    assert second.digest_kind == :packed
    refute inspect(first) =~ @reference
  end

  test "pull transmits pinned identity and explicit guest platform without invented authentication" do
    client =
      client(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/machines/fixture/images/pull"
        {:ok, body, conn} = TestPeer.body(conn)
        assert Jason.decode!(body) == %{"image" => @reference, "ociPlatform" => "linux/amd64"}
        TestPeer.json(conn, %{"image" => image()})
      end)

    assert {:ok, %Image{digest_kind: :configuration, digest: digest}} =
             Client.pull_image(client, "fixture", source())

    assert digest == "sha256:" <> @config
    refute digest == "sha256:" <> @manifest
  end

  test "pull mismatch remains uncertain, including packed imports and other platforms" do
    for body <- [
          Map.put(image(), "reference", "different"),
          Map.put(image(), "architecture", "arm64"),
          Map.put(image(), "os", "windows"),
          Map.put(image(), "digest", "packed"),
          Map.put(image(), "digest", "arbitrary"),
          Map.put(image(), "size", -1),
          Map.put(image(), "layerCount", -1),
          Map.delete(image(), "reference")
        ] do
      client = client(&TestPeer.json(&1, %{"image" => body}))

      assert {:error,
              %Error{category: :protocol, operation: :pull_image, evidence: :dispatch_uncertain}} =
               Client.pull_image(client, "fixture", source())
    end
  end

  test "invalid inventories fail as a whole and never become an empty successful result" do
    for body <- [
          %{},
          %{"images" => nil},
          %{"images" => [%{}]},
          %{"images" => List.duplicate(image(), 1025)}
        ] do
      assert {:error, %Error{category: :protocol}} = ImageInventory.from_wire(body)
    end

    assert {:error, %Error{}} = Image.validate(%{})
    {:ok, observed} = Image.from_wire(image())
    assert {:error, %Error{}} = Image.validate(Map.put(observed, :secret, "credential"))
  end

  test "name and source validation happens before contacting the worker" do
    client = client(fn _conn -> flunk("unexpected request") end)
    assert {:error, %Error{category: :validation}} = Client.list_images(client, "../other")
    assert {:error, %Error{category: :validation}} = Client.pull_image(client, "fixture", %{})

    {:ok, registry} =
      Source.registry(
        id: "prepared",
        reference: @reference,
        architecture: "x86_64",
        content_sha256: @config
      )

    assert {:error, %Error{category: :validation}} =
             Client.pull_image(client, "fixture", registry)
  end

  defp source do
    {:ok, source} = Source.oci(id: "app", reference: @reference, architecture: "x86_64")
    source
  end

  defp image,
    do: %{
      "reference" => @reference,
      "digest" => "sha256:" <> @config,
      "size" => 1024,
      "architecture" => "amd64",
      "os" => "linux",
      "layerCount" => 1
    }

  defp client(handler) do
    port =
      TestPeer.start(fn conn ->
        if conn.request_path == "/health",
          do: TestPeer.json(conn, %{"status" => "ok", "version" => "1.19.0"}),
          else: handler.(conn)
      end)

    {:ok, worker} =
      Worker.new("images-peer", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(worker)
    client
  end
end
