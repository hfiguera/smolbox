defmodule SmolBox.MeasurementsClientTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Client, TestPeer, Worker}

  test "observation endpoints use GET and preserve identity and media contracts" do
    peer =
      client(fn conn ->
        assert conn.method == "GET"

        case conn.request_path do
          "/capacity" ->
            TestPeer.json(conn, capacity())

          "/metrics" ->
            assert Plug.Conn.get_req_header(conn, "accept") == ["text/plain"]

            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain; version=0.0.4")
            |> Plug.Conn.send_resp(200, "# TYPE vm_count gauge\nvm_count 0\n")

          "/api/v1/machines/fixture" ->
            TestPeer.json(conn, machine())
        end
      end)

    assert {:ok, %{used_cpus: 0.25}} = Client.capacity(peer)
    assert {:ok, text} = Client.metrics(peer)
    assert text =~ "vm_count 0"

    assert {:ok, %{machine: %{name: "fixture"}, cpu_millis: nil}} =
             Client.machine_measurements(peer, "fixture")

    assert {:error, %{category: :validation}} = Client.machine_measurements(peer, "../escape")

    wrong = client(&TestPeer.json(&1, Map.put(machine(), "name", "other")))
    assert {:error, %{category: :protocol}} = Client.machine_measurements(wrong, "fixture")
  end

  test "worker errors, invalid text and oversized responses are not fabricated zero measurements" do
    down = client(&Plug.Conn.send_resp(&1, 503, "private diagnostic"))

    for result <- [
          Client.capacity(down),
          Client.metrics(down),
          Client.machine_measurements(down, "fixture")
        ] do
      assert {:error, error} = result
      refute inspect(error) =~ "private diagnostic"
    end

    for {type, body} <- [{"text/html", "proxy"}, {"text/plain", <<255>>}] do
      peer =
        client(fn conn ->
          conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
        end)

      assert {:error, %{category: :protocol}} = Client.metrics(peer)
    end

    large = client(&TestPeer.json(&1, capacity()), max_response_bytes: 10)
    assert {:error, %{category: :output_limit}} = Client.capacity(large)

    text =
      client(
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(200, String.duplicate("x", 50))
        end,
        max_response_bytes: 10
      )

    assert {:error, %{category: :output_limit}} = Client.metrics(text)
  end

  defp capacity,
    do: %{
      "allocated_cpus" => 0,
      "allocated_memory_mb" => 0,
      "used_cpus" => 0.25,
      "used_memory_mb" => 0,
      "used_disk_gb" => 0
    }

  defp machine, do: "test/fixtures/wire/created.json" |> File.read!() |> Jason.decode!()

  defp client(handler, options \\ []) do
    port = TestPeer.start(handler)

    {:ok, worker} =
      Worker.new(
        "measurements",
        "http://127.0.0.1:#{port}",
        [allow_insecure_loopback: true] ++ options
      )

    {:ok, client} = Client.new(worker)
    client
  end
end
