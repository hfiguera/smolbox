defmodule SmolBox.ClientTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Client, Command, Error, Files, MachineSpec, Result, TestPeer, Worker}

  defp client(handler, worker_options \\ []) do
    port = TestPeer.start(handler)

    {:ok, worker} =
      Worker.new(
        "peer",
        "http://127.0.0.1:#{port}",
        [allow_insecure_loopback: true] ++ worker_options
      )

    {:ok, client} = Client.new(worker)
    client
  end

  defp fixture(name), do: "test/fixtures/wire/#{name}.json" |> File.read!() |> Jason.decode!()

  test "health and empty readiness responses use distinct strict wire contracts" do
    peer =
      client(fn conn ->
        case conn.request_path do
          "/health" -> TestPeer.json(conn, fixture("health"))
          "/readyz" -> Plug.Conn.send_resp(conn, 200, "")
          "/api/v1/machines" -> Plug.Conn.send_resp(conn, 200, "")
        end
      end)

    assert {:ok, %{version: "1.14.1", total: 0, running: 0}} = Client.health(peer)

    for version <- ["1.14.6", "1.16.0", "1.16.1"] do
      upgraded = client(&TestPeer.json(&1, fixture(version <> "/health")))
      assert {:ok, %{version: ^version, total: 0, running: 0}} = Client.health(upgraded)
    end

    assert :ok = Client.readiness(peer)
    assert {:error, %Error{category: :protocol}} = Client.list(peer)

    proxy =
      client(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "")
      end)

    assert :ok = Client.readiness(proxy)

    for {status, body} <- [{503, ""}, {401, ""}, {302, ""}, {200, "x"}, {200, "not empty"}] do
      peer = client(&Plug.Conn.send_resp(&1, status, body))
      assert {:error, %Error{operation: :readiness}} = Client.readiness(peer)
    end
  end

  test "actual HTTP lifecycle bodies, paths, media types and names round trip" do
    parent = self()

    client =
      client(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)
        send(parent, {:request, conn.method, conn.request_path, body})

        case {conn.method, conn.request_path} do
          {"DELETE", _path} ->
            TestPeer.json(conn, %{"deleted" => "fixture"})

          {"GET", "/api/v1/machines"} ->
            TestPeer.json(conn, %{"machines" => [fixture("created")]})

          {_method, _path} ->
            TestPeer.json(conn, fixture("created"))
        end
      end)

    {:ok, spec} = MachineSpec.new("fixture", "/approved/python.smolmachine")
    assert {:ok, machine} = Client.create(client, spec)
    assert machine.state == :created
    assert_receive {:request, "POST", "/api/v1/machines", body}
    wire = Jason.decode!(body)
    assert wire["entrypoint"] == ["/bin/true"]
    assert wire["network"] == false
    assert {:ok, [^machine]} = Client.list(client)
    assert {:ok, ^machine} = Client.inspect_machine(client, "fixture")
    assert {:ok, ^machine} = Client.start(client, "fixture")
    assert {:ok, ^machine} = Client.stop(client, "fixture")
    assert :ok = Client.delete(client, "fixture")
    assert_receive {:request, "POST", "/api/v1/machines/fixture/start", "{}"}
    assert_receive {:request, "POST", "/api/v1/machines/fixture/stop", "{}"}
    assert_receive {:request, "DELETE", "/api/v1/machines/fixture", ""}
  end

  test "network creation verifies runtime and exact returned policy without retry" do
    {:ok, policy} = SmolBox.NetworkPolicy.new(hosts: ["api.example.com"])
    {:ok, spec} = MachineSpec.new("fixture", "/approved/python.smolmachine", network: policy)
    parent = self()

    supported_cases =
      for version <- ["1.16.0", "1.16.1"],
          mode <- [:matching, :missing, :different],
          do: {version, mode}

    for {version, mode} <- supported_cases ++ [{"1.14.6", :legacy}, {"1.16.2", :legacy}] do
      peer =
        client(fn conn ->
          if conn.request_path == "/health" do
            TestPeer.json(conn, Map.put(fixture("health"), "version", version))
          else
            {:ok, body, conn} = TestPeer.body(conn)
            send(parent, {:created, mode, Jason.decode!(body)})
            response = Map.merge(fixture("created"), SmolBox.NetworkPolicy.to_wire(policy))

            response =
              case mode do
                :matching -> response
                :missing -> Map.delete(response, "allowedHosts")
                :different -> Map.put(response, "allowedHosts", ["other.example.com"])
              end

            TestPeer.json(conn, response)
          end
        end)

      case mode do
        :matching ->
          assert {:ok, %{network: ^policy}} = Client.create(peer, spec)

        :legacy ->
          assert {:error, %Error{category: :unsupported_capability}} = Client.create(peer, spec)

        _ ->
          assert {:error, %Error{evidence: :dispatch_uncertain}} = Client.create(peer, spec)
      end

      if mode == :legacy do
        refute_receive {:created, ^mode, _}
      else
        assert_receive {:created, ^mode,
                        %{
                          "network" => true,
                          "allowedHosts" => ["api.example.com"],
                          "allowedCidrs" => [],
                          "networkBackend" => "virtio-net"
                        }}

        refute_receive {:created, ^mode, _}
      end
    end
  end

  test "network preflight and create share one operation budget" do
    parent = self()
    {:ok, policy} = SmolBox.NetworkPolicy.new(hosts: ["api.example.com"])
    {:ok, spec} = MachineSpec.new("fixture", "/approved/python.smolmachine", network: policy)

    peer =
      client(
        fn conn ->
          if conn.request_path == "/health" do
            Process.sleep(250)
            TestPeer.json(conn, Map.put(fixture("health"), "version", "1.16.0"))
          else
            send(parent, :create_dispatched)
            Process.sleep(900)

            TestPeer.json(
              conn,
              Map.merge(fixture("created"), SmolBox.NetworkPolicy.to_wire(policy))
            )
          end
        end,
        operation_timeout_ms: 1000
      )

    assert {:error, %Error{evidence: :dispatch_uncertain}} = Client.create(peer, spec)
    assert_receive :create_dispatched
    refute_receive :create_dispatched
  end

  test "a failed network preflight has not dispatched creation" do
    parent = self()
    {:ok, policy} = SmolBox.NetworkPolicy.new(hosts: ["api.example.com"])
    {:ok, spec} = MachineSpec.new("fixture", "/approved/python.smolmachine", network: policy)

    peer =
      client(fn conn ->
        send(parent, {:preflight_path, conn.request_path})
        Plug.Conn.send_resp(conn, 503, "")
      end)

    assert {:error, %Error{operation: :create, evidence: :not_dispatched}} =
             Client.create(peer, spec)

    assert_receive {:preflight_path, "/health"}
    refute_receive {:preflight_path, "/api/v1/machines"}

    invalid = %{peer | worker: %{peer.worker | operation_timeout_ms: nil}}
    assert {:error, %Error{category: :validation}} = Client.create(invalid, spec)
    refute_receive {:preflight_path, _}
  end

  test "exec preserves argv and byte-exact nonzero output without inventing shell semantics" do
    parent = self()

    client =
      client(fn conn ->
        {:ok, bytes, conn} = TestPeer.body(conn)
        send(parent, {:wire, Jason.decode!(bytes)})

        TestPeer.json(conn, %{
          "exitCode" => 7,
          "stdoutB64" => Base.encode64(<<0, 255>>),
          "stderrB64" => Base.encode64("err")
        })
      end)

    {:ok, command} =
      Command.new(["echo", "$(touch /bad); literal"], stdin: "secret", env: [{"TOKEN", "value"}])

    assert {:ok, %Result{exit_code: 7, stdout: <<0, 255>>, stderr: "err"}} =
             Client.exec(client, "fixture", command)

    assert_receive {:wire,
                    %{
                      "command" => ["echo", "$(touch /bad); literal"],
                      "stdin" => "secret",
                      "timeoutSecs" => 30,
                      "background" => false
                    }}

    refute inspect(client) =~ "Bearer"

    assert {:error, %Error{category: :output_limit, exit_code: 7}} =
             Client.exec(client, "fixture", command, max_output_bytes: 1)
  end

  test "binary upload checks digest before HTTP and escapes each guest path component once" do
    parent = self()
    bytes = <<0, 255, 10>>

    client =
      client(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)
        send(parent, {:file, conn.method, conn.request_path, body})

        if conn.method == "PUT" do
          TestPeer.json(conn, %{"path" => "/workspace/café a.bin", "size" => byte_size(body)})
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.send_resp(200, bytes)
        end
      end)

    assert :ok =
             Client.upload(client, "fixture", "/workspace/café a.bin", bytes, Files.sha256(bytes))

    assert_receive {:file, "PUT", "/api/v1/machines/fixture/files/workspace/caf%C3%A9%20a.bin",
                    ^bytes}

    assert {:ok, ^bytes} = Client.download(client, "fixture", "/workspace/café a.bin", 3)
    assert_receive {:file, "GET", _path, ""}

    assert {:error, %Error{category: :output_limit}} =
             Client.download(client, "fixture", "/workspace/café a.bin", 2)

    assert_receive {:file, "GET", _path, ""}

    assert {:error, %Error{evidence: :not_dispatched}} =
             Client.upload(client, "fixture", "/workspace/a", bytes, Files.sha256("different"))

    refute_receive {:file, _method, _path, _body}
  end

  test "invalid options, names, commands and unsafe files are rejected before the peer sees I/O" do
    parent = self()

    client =
      client(fn conn ->
        send(parent, :unexpected_io)
        TestPeer.json(conn, %{})
      end)

    {:ok, command} = Command.new(["true"])

    for call <- [
          fn -> Client.create(client, nil) end,
          fn -> Client.start(client, "../foreign") end,
          fn -> Client.exec(client, "fixture", nil) end,
          fn -> Client.exec(client, "fixture", command, retry: true) end,
          fn -> Client.exec_stream(client, "fixture", %{command | stdin: "input"}) end,
          fn -> Client.exec_stream(client, "fixture", command, on_event: :invalid) end,
          fn -> Client.exec_stream(client, "fixture", nil) end,
          fn -> Client.download(client, "fixture", "/etc/passwd", 1) end,
          fn -> Client.download(client, "fixture", "/workspace/a", 0) end,
          fn -> Client.upload(client, "fixture", "/workspace/a", :invalid, "digest") end
        ] do
      assert {:error, %Error{evidence: :not_dispatched}} = call.()
    end

    for options <- [[unknown: true], [transport: :missing_module], [transport: nil]] do
      assert {:error, _} = Client.new(client.worker, options)
    end

    assert {:error, _} = Client.new(nil)
    refute_receive :unexpected_io
  end

  test "malformed JSON, unsafe machines, wrong ownership and invalid acknowledgments fail closed" do
    invalid_bodies = [%{}, %{"machines" => [%{}]}, %{"machines" => List.duplicate(%{}, 1025)}]

    for body <- invalid_bodies do
      client = client(&TestPeer.json(&1, body))
      assert {:error, _} = Client.list(client)
    end

    client = client(&TestPeer.json(&1, fixture("created")))

    assert {:error, %Error{category: :identity_conflict}} =
             Client.inspect_machine(client, "other")

    assert {:error, _} = Client.delete(client, "fixture")
    assert {:error, _} = Client.upload(client, "fixture", "/workspace/a", "a", Files.sha256("a"))

    invalid =
      client(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{broken-secret")
      end)

    assert {:error, error} = Client.list(invalid)
    refute inspect(error) =~ "secret"
  end
end
