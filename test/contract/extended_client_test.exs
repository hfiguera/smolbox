defmodule SmolBox.ExtendedClientTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, Command, Error, LaunchResult, TestPeer, Worker}

  test "quiet buffered and streaming long commands use the explicit operation budget" do
    port =
      TestPeer.start(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)

        case conn.path_info do
          ["health"] ->
            TestPeer.json(conn, %{"status" => "ok", "version" => "1.17.0"})

          ["api", "v1", "machines", "owned", "exec" | suffix] ->
            assert Jason.decode!(body)["timeoutSecs"] == 600
            Process.sleep(1000)

            if suffix == [] do
              TestPeer.json(conn, wire("finished"))
            else
              conn
              |> Plug.Conn.put_resp_content_type("text/event-stream")
              |> Plug.Conn.send_resp(
                200,
                "event: stdout\ndata: finished\n\nevent: exit\ndata: {\"exitCode\":0}\n\n"
              )
            end
        end
      end)

    client = client(port)
    {:ok, command} = Command.new(["build"], timeout_secs: 600)

    for operation <- [:exec, :exec_stream] do
      assert {:ok, %{exit_code: 0, stdout: "finished"}} =
               apply(Client, operation, [client, "owned", command])
    end
  end

  test "background launch checks version and image support, uses buffered PID decoding and rejects streaming" do
    port =
      TestPeer.start(fn conn ->
        {:ok, body, conn} = TestPeer.body(conn)

        case conn.path_info do
          ["health"] ->
            TestPeer.json(conn, %{"status" => "ok", "version" => "1.17.0"})

          ["api", "v1", "machines", "owned"] ->
            TestPeer.json(conn, machine("python"))

          ["api", "v1", "machines", "owned", "exec"] ->
            command = Jason.decode!(body)
            assert command["background"] == true
            refute Map.has_key?(command, "timeoutSecs")
            TestPeer.json(conn, wire("pid=321\n"))
        end
      end)

    {:ok, command} = Command.new(["server"], background: true)
    assert {:ok, %LaunchResult{pid: 321}} = Client.exec(client(port), "owned", command)

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Client.exec_stream(client(port), "owned", command)
  end

  test "old runtimes and unsupported machine types reject before exec dispatch" do
    for {version, observation, category} <- [
          {"1.16.1", machine("python"), :unsupported_capability},
          {"1.17.0", machine(nil), :unsupported_capability},
          {"1.17.0", Map.delete(machine("python"), "branchable"), :unsupported_capability},
          {"1.17.0", Map.put(machine("python"), "name", "other"), :identity_conflict},
          {"1.17.0", [], :protocol}
        ] do
      port =
        TestPeer.start(fn conn ->
          case conn.path_info do
            ["health"] -> TestPeer.json(conn, %{"status" => "ok", "version" => version})
            ["api", "v1", "machines", "owned"] -> TestPeer.json(conn, observation)
            _unexpected -> flunk("unexpected worker mutation")
          end
        end)

      {:ok, command} = Command.new(["server"], background: true)

      assert {:error, %Error{category: ^category, evidence: :not_dispatched}} =
               Client.exec(client(port), "owned", command)
    end
  end

  defp machine(image) do
    "test/fixtures/wire/created.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"name" => "owned", "image" => image, "branchable" => false})
  end

  defp client(port) do
    {:ok, worker} =
      Worker.new("extended", "http://127.0.0.1:#{port}",
        allow_insecure_loopback: true,
        receive_timeout_ms: 500,
        operation_timeout_ms: 10_000
      )

    {:ok, client} = Client.new(worker)
    client
  end

  defp wire(stdout),
    do: %{"exitCode" => 0, "stdoutB64" => Base.encode64(stdout), "stderrB64" => ""}
end
