defmodule SmolBox.StreamTransportTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Client, Command, Error, Result, TestPeer, Worker}

  defp stream(parts, options \\ []) do
    port =
      TestPeer.start(fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce_while(parts, conn, &TestPeer.stream_chunk/2)
      end)

    {:ok, worker} =
      Worker.new("stream", "http://127.0.0.1:#{port}", [allow_insecure_loopback: true] ++ options)

    {:ok, client} = Client.new(worker)
    client
  end

  test "real fragmented chunks preserve stream order and explicit lossy encoding" do
    bytes = File.read!("test/fixtures/wire/exec.sse")
    chunks = for <<byte <- bytes>>, do: <<byte>>
    client = stream(chunks)
    parent = self()
    {:ok, command} = Command.new(["true"])

    assert {:ok, %Result{exit_code: 0, stdout: "café\n", stderr: "", encoding: :lossy_utf8}} =
             Client.exec_stream(client, "fixture", command, on_event: &send(parent, {:event, &1}))

    assert_receive {:event, {:stdout, "café\n"}}
    assert_receive {:event, {:exit, 0}}
  end

  test "missing exit, malformed event and duplicate terminal never become success" do
    {:ok, command} = Command.new(["true"])

    for bytes <- [
          "",
          "event: stdout\ndata: hello\n\n",
          "event: exit\ndata: bad\n\n",
          "event: error\ndata: {\"message\":\"secret\"}\n\n",
          "event: exit\ndata: {\"exitCode\":0}\n\nevent: exit\ndata: {\"exitCode\":0}\n\n"
        ] do
      assert {:error, %Error{evidence: :dispatch_uncertain} = error} =
               Client.exec_stream(stream([bytes]), "fixture", command)

      refute inspect(error) =~ "secret"
    end
  end

  test "output and total framing budgets bound capture including ignored events" do
    {:ok, command} = Command.new(["true"])
    client = stream(["event: stderr\ndata: too much\n\n"])

    assert {:error, %Error{category: :output_limit}} =
             Client.exec_stream(client, "fixture", command, max_output_bytes: 2)

    ignored = stream([String.duplicate(": keepalive\n\n", 200)], max_response_bytes: 50)

    assert {:error, %Error{category: :output_limit}} =
             Client.exec_stream(ignored, "fixture", command)

    large_frame = stream(["event: stdout\ndata: " <> String.duplicate("a", 140_000)])

    assert {:error, %Error{category: :output_limit}} =
             Client.exec_stream(large_frame, "fixture", command)
  end

  test "crashing observers detach while slow observers are bounded by the operation deadline" do
    {:ok, command} = Command.new(["true"])
    bytes = "event: stderr\ndata: err\n\nevent: exit\ndata: {\"exitCode\":2}\n\n"

    for callback <- [
          fn _event -> raise "private observer data" end,
          fn _event -> throw(:private) end
        ] do
      assert {:ok, %Result{exit_code: 2, stderr: "err"}} =
               Client.exec_stream(stream([bytes]), "fixture", command, on_event: callback)
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{category: :transport, evidence: :dispatch_uncertain}} =
             Client.exec_stream(stream([bytes], operation_timeout_ms: 100), "fixture", command,
               on_event: fn _event -> Process.sleep(10_000) end
             )

    assert System.monotonic_time(:millisecond) - started < 2000
  end
end
