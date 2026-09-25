defmodule SmolBox.GuestFilesTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Command, Files, GuestPaths, TestPeer, Worker}

  defp client(handler, options \\ []) do
    parent = self()

    port =
      TestPeer.start(fn conn ->
        send(parent, {"request", conn.method, conn.request_path})

        case conn.request_path do
          "/health" ->
            TestPeer.json(conn, %{
              "status" => "ok",
              "version" => Keyword.get(options, :version, "1.17.0"),
              "machines" => %{"total" => 1, "running" => 1},
              "uptime_seconds" => 0
            })

          "/api/v1/machines/app" ->
            body =
              "test/fixtures/wire/1.17.0/running.json"
              |> File.read!()
              |> Jason.decode!()
              |> Map.merge(%{
                "name" => "app",
                "image" => "python:fixture",
                "branchable" => Keyword.get(options, :checkpoint, false)
              })

            TestPeer.json(conn, body)

          _ ->
            handler.(conn)
        end
      end)

    {:ok, worker} =
      Worker.new("files", "http://127.0.0.1:#{port}",
        allow_insecure_loopback: true,
        max_request_bytes: 16_777_216,
        operation_timeout_ms: Keyword.get(options, :timeout, 30_000)
      )

    {:ok, policy} =
      GuestPaths.new(
        upload_roots: ["/app", "/home/dev"],
        download_roots: ["/out"],
        workdir_roots: ["/app"]
      )

    {:ok, client} = Client.new(worker, guest_paths: policy, max_file_bytes: 16_777_216)
    client
  end

  test "larger binary upload and download preserve exact bytes and route encoding" do
    bytes = :binary.copy(<<0, 255, 13>>, 400_000)

    peer =
      client(fn conn ->
        case conn.method do
          "PUT" ->
            assert conn.request_path == "/api/v1/machines/app/files/app/caf%C3%A9%20input"
            {:ok, ^bytes, conn} = TestPeer.body(conn)
            TestPeer.json(conn, %{"path" => "/app/café input", "size" => byte_size(bytes)})

          "GET" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_resp(200, bytes)

          "POST" ->
            {:ok, body, conn} = TestPeer.body(conn)
            assert Jason.decode!(body)["workdir"] == "/app"
            TestPeer.json(conn, %{"exitCode" => 0, "stdoutB64" => "", "stderrB64" => ""})
        end
      end)

    assert :ok = Client.upload(peer, "app", "/app/café input", bytes, Files.sha256(bytes))
    assert {:ok, ^bytes} = Client.download(peer, "app", "/out/result", byte_size(bytes))
    {:ok, command} = Command.new(["true"], workdir: "/app")
    assert {:ok, %{exit_code: 0}} = Client.exec(peer, "app", command)
    assert {:error, %{category: :output_limit}} = Client.download(peer, "app", "/out/result", 100)
  end

  test "unapproved paths, default budgets and bad digests are rejected before any worker access" do
    peer = client(fn _ -> flunk("unexpected file mutation") end)
    {:ok, default} = Client.new(peer.worker)
    bytes = :binary.copy(<<0>>, 1_048_577)

    assert {:error, _} =
             Client.upload(default, "app", "/workspace/in", bytes, Files.sha256(bytes))

    assert {:error, _} = Client.upload(peer, "app", "/application/in", "x", Files.sha256("x"))
    assert {:error, _} = Client.download(peer, "app", "/home/dev/.config", 10)
    assert {:error, _} = Client.upload(peer, "app", "/app/in", "x", Files.sha256("wrong"))
    assert {:error, _} = Client.download(peer, "app", "/out/x", 16_777_217)
    {:ok, command} = Command.new(["true"], workdir: "/app")
    assert {:error, _} = Client.exec(default, "app", command)
    assert {:error, _} = Client.exec_stream(default, "app", command)
    refute_receive {"request", _, _}, 30
  end

  test "unqualified workers and checkpoints fail preflight without transferring" do
    for options <- [[version: "1.16.1"], [checkpoint: true]] do
      peer = client(fn _ -> flunk("unexpected file transfer") end, options)

      assert {:error, %{category: :unsupported_capability}} =
               Client.upload(peer, "app", "/app/in", "x", Files.sha256("x"))
    end
  end

  test "an uncertain upload is never replayed and deadlines bound file observation" do
    parent = self()

    peer =
      client(fn conn ->
        send(parent, :mutated)
        Plug.Conn.send_resp(conn, 503, "private failure")
      end)

    assert {:error, error} = Client.upload(peer, "app", "/app/in", "x", Files.sha256("x"))
    refute inspect(error) =~ "private"
    assert_receive :mutated
    refute_receive :mutated, 50

    peer =
      client(
        fn conn ->
          Process.sleep(2000)
          Plug.Conn.send_resp(conn, 200, "")
        end,
        timeout: 100
      )

    before = System.monotonic_time(:millisecond)
    assert {:error, %{category: category}} = Client.download(peer, "app", "/out/file", 100)
    # Preflight shares the operation budget: it may expire before the stalled
    # transfer starts, while expiry inside the transport is a transport error.
    assert category in [:expired, :transport]
    assert System.monotonic_time(:millisecond) - before < 1500
  end
end
