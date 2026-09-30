defmodule SmolBox.VolumeClientTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Machine, MachineSpec, Mount, TestPeer, Worker}

  test "provision uses the upstream snake case payload and deletion requires an exact 204" do
    parent = self()

    c =
      client(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)
        send(parent, {conn.method, conn.request_path, body})

        case conn.method do
          "POST" -> TestPeer.json(conn, %{"node_path" => "/owned/volumes/data"})
          "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    assert {:ok, "/owned/volumes/data"} = Client.provision_volume(c, "data", 2)
    assert_receive {"POST", "/api/v1/volumes", body}
    assert Jason.decode!(body) == %{"id" => "data", "size_gb" => 2, "backend" => "local"}
    assert :ok = Client.delete_volume(c, "data")
    assert_receive {"DELETE", "/api/v1/volumes/data", ""}

    for status <- [200, 404, 500] do
      bad = client(&Plug.Conn.send_resp(&1, status, ""))
      assert {:error, _} = Client.delete_volume(bad, "data")
    end
  end

  test "unsafe IDs, advisory sizes, unexpected paths and unsupported versions fail closed" do
    parent = self()

    c =
      client(fn conn ->
        send(parent, :mutation)
        TestPeer.json(conn, %{"node_path" => "/owned/../other"})
      end)

    for id <- ["../data", "a/b", "", String.duplicate("x", 129)] do
      assert {:error, %{category: :validation}} = Client.provision_volume(c, id, 1)
      assert {:error, %{category: :validation}} = Client.delete_volume(c, id)
    end

    for size <- [0, 1025, "1"] do
      assert {:error, %{category: :validation}} = Client.provision_volume(c, "data", size)
    end

    refute_received :mutation
    assert {:error, %{category: :protocol}} = Client.provision_volume(c, "data", 2)
    assert_receive :mutation

    old =
      client(
        fn conn ->
          send(parent, :mutation)
          TestPeer.json(conn, %{})
        end,
        "1.19.0"
      )

    assert {:error, %{category: :unsupported_capability}} =
             Client.provision_volume(old, "data", 1)

    assert {:error, %{category: :unsupported_capability}} = Client.delete_volume(old, "data")
    refute_received :mutation
  end

  test "machine creation roundtrips immutable mounts and rejects changed or staged observations" do
    {:ok, mount} = Mount.new("/approved/data", "/mnt/volumes/data", readonly: true)
    {:ok, spec} = MachineSpec.new("fixture", "/approved/app.smolmachine", mounts: [mount])
    parent = self()

    c =
      client(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)
        send(parent, {:wire, Jason.decode!(body)})
        TestPeer.json(conn, Map.put(fixture("created"), "mounts", Mount.to_wire([mount])))
      end)

    assert {:ok, %{mounts: [^mount]} = observed} = Client.create(c, spec)
    assert_receive {:wire, %{"mounts" => [%{"staged" => false, "readonly" => true}]}}
    refute Machine.same_incarnation?(observed, %{observed | mounts: []})

    changed =
      client(fn conn -> TestPeer.json(conn, Map.put(fixture("created"), "mounts", [])) end)

    assert {:error, _} = Client.create(changed, spec)
    staged = hd(Mount.to_wire([mount])) |> Map.put("staged", true)
    assert {:error, _} = Machine.from_wire(Map.put(fixture("created"), "mounts", [staged]))
  end

  defp fixture(name),
    do: "test/fixtures/wire/1.19.0/#{name}.json" |> File.read!() |> Jason.decode!()

  defp client(handler, version \\ "1.20.2") do
    port =
      TestPeer.start(fn conn ->
        if conn.request_path == "/health",
          do: TestPeer.json(conn, Map.put(fixture("health"), "version", version)),
          else: handler.(conn)
      end)

    {:ok, worker} =
      Worker.new("volume-peer", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(worker)
    client
  end
end
