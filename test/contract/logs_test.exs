defmodule SmolBox.LogsTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, LogResult, MachineSpec, TestPeer, Worker, Workload}

  defp client(handler, options \\ [], version \\ "1.17.0") do
    port =
      TestPeer.start(fn conn ->
        if conn.request_path == "/health" do
          TestPeer.json(conn, %{
            "status" => "ok",
            "version" => version,
            "machines" => %{"total" => 1, "running" => 1},
            "uptime_seconds" => 0
          })
        else
          handler.(conn)
        end
      end)

    {:ok, worker} =
      Worker.new("logs", "http://127.0.0.1:#{port}", [allow_insecure_loopback: true] ++ options)

    {:ok, client} = Client.new(worker)
    client
  end

  defp stream(bytes, options \\ []) do
    client(
      fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce_while(for(<<byte <- bytes>>, do: <<byte>>), conn, &TestPeer.stream_chunk/2)
      end,
      options
    )
  end

  test "fragmented console text and additive events are distinct from exec output" do
    parent = self()

    peer =
      client(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v1/machines/app/logs"
        assert URI.decode_query(conn.query_string) == %{"tail" => "0", "follow" => "true"}

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: ready\n\n")
      end)

    assert {:ok, %LogResult{lines: ["ready"], source: :console}} =
             Client.logs(peer, "app", tail: 0, follow: true, on_event: &send(parent, &1))

    assert_receive {:log, "ready"}

    bytes =
      ": keepalive\n\ndata: café\ndata: second\n\nevent: exit\ndata: invalid-exec-payload\n\ndata: error: read failed\n\n"

    assert {:ok, %LogResult{lines: ["café\nsecond", "error: read failed"], encoding: :lossy_utf8}} =
             Client.logs(stream(bytes), "app")

    assert {:ok, %LogResult{lines: []}} = Client.logs(stream(""), "app")
    refute inspect(%LogResult{lines: ["private"]}) =~ "private"
  end

  test "bounds, unfinished frames and invalid UTF8 are errors with no transcript leakage" do
    for bytes <- ["data: incomplete", "data: incomplete\n", "data: " <> <<255>> <> "\n\n"] do
      assert {:error, %{category: :protocol, operation: :logs}} =
               Client.logs(stream(bytes), "app")
    end

    assert {:error, %{category: :output_limit}} =
             Client.logs(stream("data: private\n\n"), "app", max_output_bytes: 2)

    assert {:error, %{category: :output_limit}} =
             Client.logs(
               stream(String.duplicate(": keepalive\n\n", 100), max_response_bytes: 512),
               "app",
               max_output_bytes: 1
             )
  end

  test "observation callbacks detach on exception and cannot exceed the operation deadline" do
    assert {:ok, %LogResult{lines: ["ok"]}} =
             Client.logs(stream("data: ok\n\n"), "app", on_event: fn _ -> raise "private" end)

    start = System.monotonic_time(:millisecond)

    assert {:error, %{category: :transport, operation: :logs}} =
             Client.logs(stream("data: ok\n\n", operation_timeout_ms: 100), "app",
               follow: true,
               on_event: fn _ -> Process.sleep(5000) end
             )

    assert System.monotonic_time(:millisecond) - start < 2000
  end

  test "invalid options and unsupported runtime cannot issue requests" do
    peer = client(fn _ -> flunk("unexpected worker access") end)

    for options <- [
          [tail: -1],
          [tail: 10_001],
          [follow: true],
          [follow: 1],
          [timeout_ms: 0],
          [timeout_ms: 300_001],
          [max_output_bytes: 0],
          [on_event: :bad],
          [format: :json],
          [tail: 1, tail: 2]
        ] do
      assert {:error, %{category: :validation}} = Client.logs(peer, "app", options)
    end

    assert {:error, _} = Client.logs(peer, "../app")
    old = client(fn _ -> flunk("unsupported operation reached worker") end, [], "1.16.1")
    assert {:error, %{category: :unsupported_capability}} = Client.logs(old, "app")
    {:ok, workload} = Workload.new(cmd: ["server"])
    {:ok, spec} = MachineSpec.new("app", "/approved/app.smolmachine", workload: workload)
    assert {:error, %{category: :unsupported_capability}} = Client.create(old, spec)
  end

  test "HTTP failure is observed once without following redirects or exposing its body" do
    parent = self()

    for status <- [302, 401, 404, 503] do
      peer =
        client(fn conn ->
          send(parent, {:request, status})
          Plug.Conn.send_resp(conn, status, "private diagnostics")
        end)

      assert {:error, error} = Client.logs(peer, "app")
      refute inspect(error) =~ "private"
      assert_receive {:request, ^status}
      refute_receive {:request, ^status}, 30
    end
  end
end
