defmodule SmolBox.RuntimeProxy do
  @moduledoc false
  alias SmolBox.{FaultGate, TestPeer}

  def start(endpoint, gate) do
    counts =
      ExUnit.Callbacks.start_supervised!({Agent, fn -> %{exec: 0, forwarded: 0} end},
        id: make_ref()
      )

    port = TestPeer.start(&forward(&1, endpoint, gate, counts))
    {counts, port}
  end

  defp forward(conn, endpoint, gate, counts) do
    {:ok, body, conn} = TestPeer.body(conn)
    command = String.ends_with?(conn.request_path, "/exec/stream")

    if command do
      Agent.update(counts, &Map.update!(&1, :exec, fn n -> n + 1 end))
      FaultGate.hit(gate, :exec, :before)
      Agent.update(counts, &Map.update!(&1, :forwarded, fn n -> n + 1 end))
    end

    method = %{"GET" => :get, "POST" => :post, "PUT" => :put, "DELETE" => :delete}[conn.method]

    response =
      Req.request(
        method: method,
        url: endpoint.base_url <> conn.request_path,
        unix_socket: endpoint.unix_socket,
        body: body,
        headers:
          Enum.filter(conn.req_headers, fn {key, _value} -> key in ["content-type", "accept"] end),
        retry: false,
        redirect: false,
        raw: true,
        receive_timeout: endpoint.receive_timeout_ms,
        into: &capture/2
      )

    send_response(conn, response)
  end

  defp capture({:data, bytes}, {request, response}) do
    body = Req.Response.get_private(response, :bounded_body, "")

    if byte_size(body) + byte_size(bytes) <= 1_048_576 do
      {:cont, {request, Req.Response.put_private(response, :bounded_body, body <> bytes)}}
    else
      {:halt, {request, Req.Response.put_private(response, :over_limit, true)}}
    end
  end

  defp send_response(conn, {:ok, response}) do
    if Req.Response.get_private(response, :over_limit, false) do
      TestPeer.json(conn, %{}, 502)
    else
      conn =
        case Req.Response.get_header(response, "content-type") do
          [] -> conn
          [content_type] -> Plug.Conn.put_resp_content_type(conn, content_type)
        end

      conn
      |> Plug.Conn.send_resp(
        response.status,
        Req.Response.get_private(response, :bounded_body, "")
      )
    end
  end

  defp send_response(conn, {:error, _redacted}), do: TestPeer.json(conn, %{}, 502)
end
