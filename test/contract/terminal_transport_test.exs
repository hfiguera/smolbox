defmodule SmolBox.TerminalTransportTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Error, Terminal, TestPeer, Worker}
  alias SmolBox.Terminal.{Connection, Spec}
  @moduletag capture_log: true

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sbx-terminal-tls-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    SmolBox.TestTLS.create(dir)
  end

  test "WSS verifies peer and hostname and forwards authentication only to the selected worker",
       tls do
    parent = self()

    port =
      TestPeer.start(
        fn conn ->
          send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

          if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-token"],
            do: upgrade(conn),
            else: TestPeer.json(conn, %{secret: "redacted"}, 401)
        end,
        scheme: :https,
        certfile: tls.cert,
        keyfile: tls.key
      )

    {:ok, worker} =
      Worker.new("tls", "https://localhost:#{port}", token: "private-token", ca_cert_file: tls.ca)

    {:ok, spec} = Spec.new()
    assert {:ok, connection} = Connection.open(worker, "owned", spec)
    Connection.close(connection)
    assert_receive {:auth, ["Bearer private-token"]}

    assert {:error, %Error{category: :authentication} = error} =
             Connection.open(%{worker | token: "wrong"}, "owned", spec)

    refute inspect(error) =~ "redacted"
    assert_receive {:auth, ["Bearer wrong"]}

    assert {:error, %Error{category: :transport}} =
             Connection.open(%{worker | ca_cert_file: nil}, "owned", spec)

    assert {:error, %Error{category: :transport}} =
             Connection.open(%{worker | base_url: "https://127.0.0.1:#{port}"}, "owned", spec)

    refute_receive {:auth, _unexpected}
  end

  test "Unix WebSocket uses passive bounded I/O independently of the request deadline" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "sbx-terminal-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.sock"
      )

    on_exit(fn -> File.rm(socket) end)
    TestPeer.start(&route/1, ip: {:local, socket})

    {:ok, worker} =
      Worker.new("unix", "http://localhost",
        unix_socket: socket,
        operation_timeout_ms: 200,
        receive_timeout_ms: 100
      )

    {:ok, client} = Client.new(worker)
    {:ok, spec} = Spec.new(session_ms: 2000, idle_ms: 1000)
    assert {:ok, handle} = Client.open_terminal(client, "owned", spec)
    assert {:ok, {:output, "ready\r\n"}} = Terminal.next(handle)
    assert {:error, %Error{category: :expired}} = Terminal.next(handle, 300)
    assert :ok = Terminal.input(handle, "still-live")
    assert {:ok, {:output, "still-live"}} = Terminal.next(handle)
    assert :ok = Terminal.close(handle)
    assert {:ok, {:closed, {:error, %Error{operation: :terminal_close}}}} = Terminal.next(handle)
  end

  test "opening never retries or redirects the mutating upgrade" do
    parent = self()

    target =
      TestPeer.start(fn conn ->
        send(parent, :redirected)
        upgrade(conn)
      end)

    for status <- [301, 302, 307, 308, 403, 404, 409, 429, 500, 503] do
      port =
        TestPeer.start(fn conn ->
          send(parent, {:attempt, status})

          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{target}")
          |> TestPeer.json(%{secret: "remote-private"}, status)
        end)

      {:ok, worker} =
        Worker.new("http", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

      assert {:error, %Error{evidence: :dispatch_uncertain}} =
               Connection.open(worker, "owned", %Spec{})

      assert_receive {:attempt, ^status}
      refute_receive {:attempt, ^status}, 10
    end

    refute_receive :redirected
  end

  test "unsupported workers, checkpoint observations and custom transports never reach upgrade" do
    parent = self()

    for {version, image, branchable} <- [
          {"1.16.1", "python", false},
          {"1.17.0", nil, false},
          {"1.17.0", "python", true}
        ] do
      port =
        TestPeer.start(fn conn ->
          case conn.path_info do
            ["health"] ->
              TestPeer.json(conn, %{status: "ok", version: version})

            ["api", "v1", "machines", "owned"] ->
              body = File.read!("test/fixtures/wire/created.json") |> Jason.decode!()

              TestPeer.json(
                conn,
                Map.merge(body, %{"name" => "owned", "image" => image, "branchable" => branchable})
              )

            _ ->
              send(parent, :unexpected_upgrade)
              upgrade(conn)
          end
        end)

      assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
               Client.open_terminal(client(port), "owned", %Spec{})
    end

    port =
      TestPeer.start(fn conn ->
        send(parent, :unexpected_upgrade)
        route(conn)
      end)

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Client.open_terminal(
               %{client(port) | transport: SmolBox.FaultTransport},
               "owned",
               %Spec{}
             )

    refute_receive :unexpected_upgrade
  end

  test "idle expiry and finite session expiry remain observation failures" do
    port = TestPeer.start(&route/1)
    client = client(port)
    {:ok, idle} = Spec.new(session_ms: 5000, idle_ms: 1000)
    {:ok, handle} = Client.open_terminal(client, "owned", idle)
    {:ok, {:output, _}} = Terminal.next(handle)

    assert {:ok, {:closed, {:error, %Error{operation: :terminal_idle}}}} =
             Terminal.next(handle, 2000)

    {:ok, bounded} = Spec.new(session_ms: 1000, idle_ms: 1000)
    {:ok, handle} = Client.open_terminal(client, "owned", bounded)
    {:ok, {:output, _}} = Terminal.next(handle)

    assert {:ok, {:closed, {:error, %Error{operation: :terminal_session}}}} =
             Terminal.next(handle, 2000)
  end

  test "unexpected text, ambiguous exit and output after exit are not successful completion" do
    for frame <- [
          {:text, "unexpected"},
          {:text, ~s({"type":"exit","code":124})},
          [{:text, ~s({"type":"exit","code":0})}, {:binary, "late"}]
        ] do
      parent = self()
      port = TestPeer.start(fn conn -> route(conn, test_pid: parent) end)
      {:ok, handle} = Client.open_terminal(client(port), "owned", %Spec{})
      assert_receive {:terminal_peer, peer}
      send(peer, {:frames, frame})
      assert {:ok, {:output, _}} = Terminal.next(handle)
      assert {:ok, {:closed, {:error, %Error{}}}} = Terminal.next(handle)
    end
  end

  test "handshake bounds incomplete headers and closes timed out connections" do
    for {response, expected} <- [
          {"HTTP/1.1 101 Switching Protocols\r\nX-Large: " <> String.duplicate("x", 17_000),
           :protocol},
          {"HTTP/1.1", :transport}
        ] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)
      parent = self()

      peer =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1000)
          :ok = :gen_tcp.send(socket, response)
          send(parent, {:peer_closed, :gen_tcp.recv(socket, 0, 2000)})
          :gen_tcp.close(socket)
        end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        Process.exit(peer, :kill)
      end)

      worker = %{client(port).worker | operation_timeout_ms: 300}

      assert {:error, %{category: ^expected, evidence: :dispatch_uncertain}} =
               Connection.open(worker, "owned", %Spec{})

      assert_receive {:peer_closed, {:error, :closed}}, 2500
    end
  end

  test "an exit followed by an orderly close preserves confirmed evidence" do
    parent = self()
    port = TestPeer.start(fn conn -> route(conn, test_pid: parent) end)
    {:ok, handle} = Client.open_terminal(client(port), "owned", %Spec{})
    assert_receive {:terminal_peer, peer}
    send(peer, {:frames, [{:text, ~s({"type":"exit","code":9})}, {:close, 1000, ""}]})
    assert {:ok, {:output, _}} = Terminal.next(handle)
    assert {:ok, {:closed, {:ok, %Terminal.Result{exit_code: 9}}}} = Terminal.next(handle)
  end

  test "input is bounded per call and cumulatively, and process status is redacted" do
    port = TestPeer.start(&route/1)
    c = client(port)
    c = %{c | worker: %{c.worker | max_request_bytes: 10}}
    {:ok, handle} = Client.open_terminal(c, "owned", %Spec{max_input_bytes: 8})

    assert {:error, %Error{category: :validation}} =
             Terminal.input(handle, String.duplicate("x", 9))

    assert :ok = Terminal.input(handle, "private")
    status = :sys.get_status(handle.pid)
    refute inspect(status) =~ "private"
    assert {:error, %Error{category: :output_limit}} = Terminal.input(handle, "more")
  end

  defp client(port) do
    {:ok, worker} = Worker.new("http", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)
    {:ok, client} = Client.new(worker)
    client
  end

  defp route(conn, options \\ []) do
    case conn.path_info do
      ["health"] ->
        TestPeer.json(conn, %{"status" => "ok", "version" => "1.17.0"})

      ["api", "v1", "machines", "owned"] ->
        body =
          File.read!("test/fixtures/wire/created.json")
          |> Jason.decode!()
          |> Map.merge(%{"name" => "owned", "image" => "python", "branchable" => false})

        TestPeer.json(conn, body)

      _interactive ->
        upgrade(conn, options)
    end
  end

  defp upgrade(conn, options \\ []),
    do: Plug.Conn.upgrade_adapter(conn, :websocket, {SmolBox.TerminalPeer, options, []})
end
