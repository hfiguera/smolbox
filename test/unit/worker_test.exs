defmodule SmolBox.WorkerTest do
  use ExUnit.Case, async: true

  alias SmolBox.{Error, Worker}

  test "remote worker requires verified HTTPS and redacts the bearer token" do
    assert {:ok, worker} =
             Worker.new("worker-1", "https://worker.example/", token: "private-token")

    assert worker.base_url == "https://worker.example"
    refute inspect(worker) =~ "private-token"
    assert {:error, %Error{}} = Worker.validate(%{worker | token: nil})
  end

  test "loopback and Unix socket transports require explicit configuration" do
    assert {:ok, _worker} =
             Worker.new("local", "http://127.0.0.1:19470", allow_insecure_loopback: true)

    assert {:ok, _worker} =
             Worker.new("local", "http://[::1]:19470", allow_insecure_loopback: true)

    assert {:ok, _worker} =
             Worker.new("local", "http://localhost", unix_socket: "/tmp/smolbox.sock")

    assert {:error, %Error{}} = Worker.new("local", "http://localhost")
  end

  test "rejects endpoint injection, unsafe transport, and unbounded configuration" do
    for {url, options} <- [
          {"http://worker.example", [allow_insecure_loopback: true]},
          {"http://localhost.example", [allow_insecure_loopback: true]},
          {"https://user:password@worker.example", [token: "token"]},
          {"https://worker.example?key=private", [token: "token"]},
          {"https://worker.example/#fragment", [token: "token"]},
          {"https://worker.example/prefix", [token: "token"]},
          {"https://worker.example:0", [token: "token"]},
          {"https://worker.example", [token: "bad\r\nheader"]},
          {"https://worker.example", [token: "token", operation_timeout_ms: 0]},
          {"https://worker.example", [token: "token", operation_timeout_ms: 900_001]},
          {"https://worker.example", [token: "token", max_response_bytes: 33_554_433]},
          {"https://worker.example", [token: "token", ca_cert_file: "/no/such/certificate"]},
          {"https://worker.example", [token: "token", unix_socket: "/tmp/socket"]},
          {"http://localhost", [unix_socket: "relative"]},
          {"file:///tmp/socket", []},
          {"not a url", []},
          {12, []},
          {"https://worker.example", [verify: false]},
          {"https://worker.example", [token: "one", token: "two"]},
          {"https://worker.example", %{}}
        ] do
      assert {:error, %Error{category: :validation}} = Worker.new("worker", url, options)
    end

    assert {:error, %Error{}} = Worker.new("bad/id", "https://worker.example", token: "token")
    assert {:error, %Error{}} = Worker.validate(%{})
  end
end
