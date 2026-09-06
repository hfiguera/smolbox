defmodule SmolBox.TestPeer do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(options), do: options
  @impl Plug
  def call(conn, options), do: Keyword.fetch!(options, :handler).(conn)

  def start(handler, options \\ []) do
    opts =
      Keyword.merge(
        [plug: {__MODULE__, handler: handler}, ip: {127, 0, 0, 1}, port: 0, startup_log: false],
        options
      )

    pid = ExUnit.Callbacks.start_supervised!({Bandit, opts}, id: make_ref())
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  def json(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  def body(conn), do: Plug.Conn.read_body(conn, length: 2_097_152)

  def stream_chunk(part, conn) do
    case Plug.Conn.chunk(conn, part) do
      {:ok, conn} -> {:cont, conn}
      {:error, _closed} -> {:halt, conn}
    end
  end
end
