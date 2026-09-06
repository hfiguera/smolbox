defmodule SmolBox.SecurityTransportTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Client, Command, Error, TestPeer, Worker}

  @moduletag capture_log: true

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sbx-tls-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    SmolBox.TestTLS.create(dir)
  end

  defp client(port, options \\ []) do
    {:ok, worker} =
      Worker.new("http", "http://127.0.0.1:#{port}", [allow_insecure_loopback: true] ++ options)

    {:ok, client} = Client.new(worker)
    client
  end

  test "authenticated TLS verifies the peer certificate and its hostname", %{
    cert: cert,
    key: key,
    ca: ca
  } do
    parent = self()

    port =
      TestPeer.start(
        fn conn ->
          send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

          case Plug.Conn.get_req_header(conn, "authorization") do
            ["Bearer private-token"] -> TestPeer.json(conn, %{"machines" => []})
            _wrong -> TestPeer.json(conn, %{"message" => "private remote error"}, 401)
          end
        end,
        scheme: :https,
        certfile: cert,
        keyfile: key
      )

    {:ok, worker} =
      Worker.new("tls", "https://localhost:#{port}", token: "private-token", ca_cert_file: ca)

    {:ok, client} = Client.new(worker)
    assert {:ok, []} = Client.list(client)
    assert_receive {:auth, ["Bearer private-token"]}

    assert {:error, %Error{category: :authentication}} =
             Client.list(%{client | worker: %{worker | token: "wrong"}})

    assert_receive {:auth, ["Bearer wrong"]}

    assert {:error, %Error{category: :transport}} =
             Client.list(%{client | worker: %{worker | ca_cert_file: nil}})

    wrong_host = %{worker | base_url: "https://127.0.0.1:#{port}"}
    assert {:error, %Error{category: :transport}} = Client.list(%{client | worker: wrong_host})
    refute_receive {:auth, _unexpected}
  end

  test "Unix socket uses the actual Req/Finch transport" do
    socket =
      Path.join(
        System.tmp_dir!(),
        "sbx-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.sock"
      )

    on_exit(fn -> File.rm(socket) end)
    TestPeer.start(&TestPeer.json(&1, %{"machines" => []}), ip: {:local, socket})
    {:ok, worker} = Worker.new("unix", "http://localhost", unix_socket: socket)
    {:ok, client} = Client.new(worker)
    assert {:ok, []} = Client.list(client)
  end

  test "redirects never forward credentials and transient failures never replay POST" do
    parent = self()

    target =
      TestPeer.start(fn conn ->
        send(parent, :redirect_followed)
        TestPeer.json(conn, %{})
      end)

    for status <- [301, 302, 307, 308, 403, 404, 409, 429, 500, 502, 503] do
      port =
        TestPeer.start(fn conn ->
          send(parent, {:attempt, status, conn.method})

          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{target}")
          |> TestPeer.json(%{}, status)
        end)

      {:ok, command} = Command.new(["true"])

      assert {:error, %Error{evidence: :dispatch_uncertain}} =
               Client.exec(client(port, token: "private-token"), "fixture", command)

      assert_receive {:attempt, ^status, "POST"}
      refute_receive {:attempt, ^status, _method}, 10
    end

    refute_receive :redirect_followed
  end

  test "response caps apply before JSON decoding and compressed bodies are rejected" do
    cases = [
      {"application/json", nil, String.duplicate(" ", 1025), :output_limit},
      {"application/json", "gzip", :zlib.gzip(String.duplicate("x", 2_000_000)), :protocol},
      {"text/plain", nil, "{}", :protocol}
    ]

    for {type, encoding, bytes, category} <- cases do
      port =
        TestPeer.start(fn conn ->
          conn = Plug.Conn.put_resp_content_type(conn, type)

          conn =
            if encoding,
              do: Plug.Conn.put_resp_header(conn, "content-encoding", encoding),
              else: conn

          Plug.Conn.send_resp(conn, 200, bytes)
        end)

      assert {:error, %Error{category: ^category}} =
               Client.list(client(port, max_response_bytes: 1024))
    end
  end

  test "outer and idle deadlines are finite and request bounds prevent dispatch" do
    parent = self()

    port =
      TestPeer.start(fn conn ->
        send(parent, :accepted)
        Process.sleep(300)
        TestPeer.json(conn, %{"machines" => []})
      end)

    for options <- [[operation_timeout_ms: 50], [receive_timeout_ms: 50]] do
      assert {:error, %Error{category: :transport}} = Client.list(client(port, options))
      assert_receive :accepted
    end

    {:ok, command} = Command.new(["true"])

    assert {:error, %Error{evidence: :not_dispatched}} =
             Client.exec(client(port, max_request_bytes: 1), "fixture", command)

    refute_receive :accepted
  end

  test "a peer that drops the accepted connection sees exactly one exec attempt" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
        :ok = :gen_tcp.close(socket)
        next = :gen_tcp.accept(listener, 250)
        {bytes, next}
      end)

    {:ok, command} = Command.new(["true"])

    assert {:error, %Error{category: :transport, evidence: :dispatch_uncertain}} =
             Client.exec(client(port), "fixture", command)

    assert {bytes, {:error, :timeout}} = Task.await(peer, 3000)
    assert bytes =~ "POST /api/v1/machines/fixture/exec "
  end
end
