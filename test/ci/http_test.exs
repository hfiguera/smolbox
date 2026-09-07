defmodule SmolBox.CI.HTTPTest do
  use ExUnit.Case, async: false
  alias SmolBox.CI.{HTTP, Util}

  test "curl configuration cannot introduce additional requests" do
    directory = Util.temporary("smolbox-curl-config")
    previous = System.get_env("CURL_HOME")

    on_exit(fn ->
      if previous, do: System.put_env("CURL_HOME", previous), else: System.delete_env("CURL_HOME")
      File.rm_rf!(directory)
    end)

    File.write!(Path.join(directory, ".curlrc"), "url = \"http://127.0.0.1:1/unexpected\"\n")
    System.put_env("CURL_HOME", directory)
    {url, server} = serve("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    assert HTTP.request(url) == {200, "ok"}
    Task.await(server)
  end

  test "loopback probes retain binary bodies and return non-success status without retries" do
    {url, server} =
      serve(
        "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\nConnection: close\r\n\r\n" <>
          <<0, 255, 10>>
      )

    assert HTTP.request(url) == {404, <<0, 255, 10>>}
    assert Task.await(server) =~ "GET /probe HTTP/1.1"
  end

  test "redirects are returned without following their destination" do
    {url, server} =
      serve(
        "HTTP/1.1 302 Found\r\nLocation: http://example.invalid/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert HTTP.request(url) == {302, ""}
    Task.await(server)
  end

  test "oversized successful and error responses fail at the output bound" do
    for code <- [200, 500] do
      response =
        "HTTP/1.1 #{code} Response\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n" <>
          String.duplicate("x", 100_000)

      {url, server} = serve(response)
      assert_raise ArgumentError, fn -> HTTP.request(url, "GET", nil, 1024) end
      Task.await(server)
    end
  end

  test "non-loopback endpoints and credentialed URLs are rejected before dispatch" do
    for url <- ["http://example.invalid", "https://127.0.0.1", "http://secret@127.0.0.1"] do
      assert_raise ArgumentError, fn -> HTTP.request(url) end
    end
  end

  defp serve(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 3_000)
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {"http://127.0.0.1:#{port}/probe", task}
  end
end
