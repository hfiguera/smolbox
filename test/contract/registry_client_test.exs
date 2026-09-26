defmodule SmolBox.RegistryClientTest do
  use ExUnit.Case, async: true

  alias SmolBox.{ArtifactPreparation, Client, Error, MachineSpec, Source, TestPeer, Worker}

  @manifest String.duplicate("a", 64)
  @content String.duplicate("b", 64)

  test "cold and warm responses preserve both digests and never return credentials" do
    parent = self()
    source = source()

    for cached <- [false, true] do
      client =
        client(fn conn ->
          {:ok, body, conn} = TestPeer.body(conn)
          send(parent, {:warm, Jason.decode!(body)})
          TestPeer.json(conn, response(cached))
        end)

      assert {:ok, %ArtifactPreparation{} = result} =
               Client.prepare_artifact(client, source, identity_token: "scoped-secret")

      assert result.manifest_sha256 == @manifest
      assert result.content_sha256 == @content
      assert result.already_cached == cached
      refute inspect(result) =~ "scoped-secret"
      refute :erlang.term_to_binary(result) =~ "scoped-secret"

      assert_receive {:warm,
                      %{"identityToken" => "scoped-secret", "reference" => reference} = wire}

      assert reference == source.reference
      assert map_size(wire) == 2
    end
  end

  test "registry creation verifies preparation before dispatch and keeps safe workload defaults" do
    parent = self()
    source = source()

    client =
      client(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)
        send(parent, {conn.request_path, Jason.decode!(body)})

        case conn.request_path do
          "/artifacts/warm" -> TestPeer.json(conn, response(false))
          "/api/v1/machines" -> TestPeer.json(conn, fixture("created"))
        end
      end)

    {:ok, spec} = MachineSpec.new("fixture", source)
    assert {:ok, %{name: "fixture"}} = Client.create(client, spec, identity_token: "secret")
    assert_receive {"/artifacts/warm", %{"reference" => reference, "identityToken" => "secret"}}
    assert_receive {"/api/v1/machines", wire}
    assert wire["registryRef"] == reference
    assert wire["registryIdentityToken"] == "secret"
    assert wire["entrypoint"] == ["/bin/true"]
    assert wire["network"] == false
    refute Map.has_key?(wire, "from")
    refute Map.has_key?(wire, "image")
    refute Map.has_key?(wire, "blobPeers")
  end

  test "wrong or malformed blob evidence never authorizes machine creation" do
    parent = self()
    {:ok, spec} = MachineSpec.new("fixture", source())

    for body <- [
          Map.put(response(false), "digest", "sha256:" <> @manifest),
          Map.put(response(false), "sizeBytes", -1),
          Map.put(response(false), "alreadyCached", "true"),
          Map.delete(response(false), "digest"),
          %{},
          []
        ] do
      client =
        client(fn conn ->
          send(parent, {:mutation, conn.request_path})
          TestPeer.json(conn, body)
        end)

      assert {:error, %Error{category: :protocol, operation: :prepare_artifact}} =
               Client.create(client, spec)

      assert_receive {:mutation, "/artifacts/warm"}
      refute_received {:mutation, "/api/v1/machines"}
    end
  end

  test "worker authentication denial is redacted and is not retried" do
    parent = self()

    client =
      client(fn conn ->
        send(parent, :attempt)
        Plug.Conn.send_resp(conn, 401, "private registry secret leaked by remote")
      end)

    assert {:error, %Error{category: :authentication} = error} =
             Client.prepare_artifact(client, source(), identity_token: "secret")

    refute inspect(error) =~ "secret"
    assert_receive :attempt
    refute_received :attempt
  end

  test "upstream registry failures never leak a remote body or dispatch creation" do
    parent = self()

    client =
      client(fn conn ->
        send(parent, {:request, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "registry rejected token scoped-secret")
      end)

    {:ok, spec} = MachineSpec.new("fixture", source())

    assert {:error, %Error{} = error} =
             Client.create(client, spec, identity_token: "scoped-secret")

    refute inspect(error) =~ "scoped-secret"
    assert_receive {:request, "/artifacts/warm"}
    refute_received {:request, "/api/v1/machines"}
    refute_received {:request, "/artifacts/warm"}
  end

  test "invalid credentials, wrong source kinds and old runtimes fail before mutation" do
    parent = self()

    handler = fn conn ->
      send(parent, :mutation)
      TestPeer.json(conn, response(false))
    end

    supported = client(handler)

    for options <- [
          [identity_token: nil],
          [identity_token: ""],
          [identity_token: "a\nb"],
          [identity_token: String.duplicate("a", 16_385)],
          [username: "user"],
          [identity_token: "one", identity_token: "two"],
          %{}
        ] do
      assert {:error, %Error{category: :validation}} =
               Client.prepare_artifact(supported, source(), options)
    end

    {:ok, oci} = Source.oci(id: "oci", reference: source().reference, architecture: "x86_64")
    assert {:error, %Error{category: :validation}} = Client.prepare_artifact(supported, oci)

    for version <- ["1.17.0", "1.19.1"] do
      unsupported = client(handler, version: version)

      assert {:error, %Error{category: :unsupported_capability}} =
               Client.prepare_artifact(unsupported, source())

      {:ok, spec} = MachineSpec.new("fixture", source())

      assert {:error, %Error{category: :unsupported_capability}} =
               Client.create(unsupported, spec)
    end

    refute_received :mutation
  end

  test "OCI and local creation reject registry artifact credentials" do
    client = client(fn _conn -> flunk("unexpected mutation") end)
    {:ok, oci} = Source.oci(id: "oci", reference: source().reference, architecture: "x86_64")
    assert {:error, %Error{category: :validation}} = MachineSpec.new("fixture", oci)
    {:ok, policy} = SmolBox.NetworkPolicy.new(hosts: ["registry.example.com"])
    {:ok, remote} = MachineSpec.new("fixture", oci, network: policy)
    {:ok, local} = MachineSpec.new("fixture", "/approved.smolmachine")
    assert {:ok, wire} = MachineSpec.to_wire(remote)
    assert wire["image"] == oci.reference
    refute Map.has_key?(wire, "from")
    refute Map.has_key?(wire, "registryRef")

    for spec <- [remote, local] do
      assert {:error, %Error{category: :validation}} =
               Client.create(client, spec, identity_token: "secret")
    end
  end

  test "a lost warm response is bounded without starting creation or retrying the download" do
    parent = self()

    client =
      client(
        fn conn ->
          send(parent, {:waiting, self(), conn.request_path})

          receive do
            :release -> TestPeer.json(conn, response(false))
          end
        end,
        operation_timeout_ms: 1000
      )

    {:ok, spec} = MachineSpec.new("fixture", source())
    task = Task.async(fn -> Client.create(client, spec) end)
    assert_receive {:waiting, peer, "/artifacts/warm"}, 2000
    assert {:error, %Error{evidence: :dispatch_uncertain}} = Task.await(task, 3000)
    send(peer, :release)
    refute_received {:waiting, _, "/api/v1/machines"}
    refute_received {:waiting, _, "/artifacts/warm"}
  end

  defp source do
    {:ok, source} =
      Source.registry(
        id: "app",
        reference: "registry.example.com/team/app@sha256:" <> @manifest,
        architecture: "x86_64",
        content_sha256: @content
      )

    source
  end

  defp response(cached),
    do: %{"digest" => "sha256:" <> @content, "sizeBytes" => 4096, "alreadyCached" => cached}

  defp fixture(name),
    do: "test/fixtures/wire/1.19.0/#{name}.json" |> File.read!() |> Jason.decode!()

  defp client(handler, options \\ []) do
    {version, options} = Keyword.pop(options, :version, "1.19.0")

    port =
      TestPeer.start(fn conn ->
        if conn.request_path == "/health",
          do: TestPeer.json(conn, Map.put(fixture("health"), "version", version)),
          else: handler.(conn)
      end)

    {:ok, worker} =
      Worker.new(
        "registry-peer",
        "http://127.0.0.1:#{port}",
        [allow_insecure_loopback: true] ++ options
      )

    {:ok, client} = Client.new(worker)
    client
  end
end
