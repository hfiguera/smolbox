defmodule SmolBox.Terminal.Connection do
  @moduledoc false
  alias SmolBox.{Error, Worker}
  alias SmolBox.Terminal.Wire

  def open(worker, name, spec) do
    uri = URI.parse(worker.base_url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    address = if worker.unix_socket, do: {:local, worker.unix_socket}, else: uri.host
    port = if worker.unix_socket, do: 0, else: uri.port
    budget = min(worker.operation_timeout_ms, 30_000)
    tls = if worker.ca_cert_file, do: [cacertfile: worker.ca_cert_file], else: []

    options = [
      protocols: [:http1],
      mode: :passive,
      hostname: uri.host,
      transport_opts:
        [
          timeout: min(worker.connect_timeout_ms, budget),
          send_timeout: min(worker.connect_timeout_ms, min(budget, 1000)),
          send_timeout_close: true,
          buffer: 16_384,
          recbuf: 16_384
        ] ++ tls
    ]

    deadline = now() + budget

    with :ok <- Worker.validate(worker),
         {:ok, conn} <- Mint.HTTP.connect(scheme, address, port, options) do
      transport = if scheme == :https, do: :ssl, else: :gen_tcp
      conn = Mint.HTTP.put_private(conn, :smolbox_terminal_transport, transport)
      upgrade(conn, worker, name, spec, deadline, scheme)
    else
      _redacted -> error(:transport)
    end
  rescue
    _redacted -> error(:transport)
  end

  defp upgrade(conn, worker, name, spec, deadline, scheme) do
    headers = if worker.token, do: [{"authorization", "Bearer " <> worker.token}], else: []
    query = URI.encode_query(%{"cmd" => spec.program, "cols" => spec.cols, "rows" => spec.rows})
    path = "/api/v1/machines/" <> name <> "/exec/interactive?" <> query
    ws_scheme = if scheme == :https, do: :wss, else: :ws

    case Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
      {:ok, conn, ref} ->
        handshake(conn, ref, nil, [], deadline, 0, spec)

      _failed ->
        Mint.HTTP.close(conn)
        error(:transport)
    end
  end

  # Read one byte during the small handshake to cap even incomplete HTTP headers.
  defp handshake(conn, ref, status, headers, deadline, count, spec) do
    if count >= 16_384 or now() >= deadline do
      Mint.HTTP.close(conn)
      error(:protocol)
    else
      handshake_read(conn, ref, status, headers, deadline, count, spec)
    end
  end

  defp handshake_read(conn, ref, status, headers, deadline, count, spec) do
    case Mint.HTTP.recv(conn, 1, max(1, deadline - now())) do
      {:ok, conn, events} ->
        response = Enum.reduce(events, {status, headers, false}, &handshake_event(&1, &2, ref))
        handshake_next(conn, ref, response, deadline, count, spec)

      {:error, conn, _reason, _events} ->
        Mint.HTTP.close(conn)
        error(:transport)
    end
  end

  defp handshake_event({:status, ref, value}, {_s, h, d}, ref), do: {value, h, d}
  defp handshake_event({:headers, ref, value}, {s, h, d}, ref), do: {s, h ++ value, d}
  defp handshake_event({:done, ref}, {s, h, _d}, ref), do: {s, h, true}
  defp handshake_event(_event, acc, _ref), do: acc

  defp handshake_next(conn, ref, {status, headers, done}, deadline, count, spec) do
    cond do
      status in [401, 403] ->
        Mint.HTTP.close(conn)
        error(:authentication)

      status != nil and status != 101 ->
        Mint.HTTP.close(conn)
        error(:protocol)

      done ->
        finish(conn, ref, status, headers, spec)

      true ->
        handshake(conn, ref, status, headers, deadline, count + 1, spec)
    end
  end

  defp finish(conn, ref, status, headers, spec) do
    case Mint.WebSocket.new(conn, ref, status, headers, mode: :passive) do
      {:ok, conn, ws} ->
        {:ok,
         %{
           conn: conn,
           ref: ref,
           transport: Mint.HTTP.get_private(conn, :smolbox_terminal_transport),
           wire: Wire.new(ws, spec.max_buffer_bytes)
         }}

      _failed ->
        Mint.HTTP.close(conn)
        error(:protocol)
    end
  end

  def send_frame(state, frame) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(state.wire.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      {:ok, %{state | conn: conn, wire: %{state.wire | ws: ws}}}
    else
      _failed -> error(:transport)
    end
  end

  # mint_web_socket 1.0.6 declares the wrong connection type in recv/3's
  # error tuple. For HTTP/1 passive mode, receive directly from the owned socket;
  # Mint still supplies handshake verification, masking and frame decoding.
  def poll(state) do
    socket = Mint.HTTP.get_socket(state.conn)

    case state.transport.recv(socket, 0, 10) do
      {:ok, bytes} ->
        decode(state, Wire.feed(state.wire, bytes))

      {:error, :timeout} ->
        {:ok, state, []}

      {:error, _reason} ->
        error(:transport)
    end
  rescue
    _redacted -> error(:transport)
  end

  defp decode(state, {:ok, wire, frames}), do: {:ok, %{state | wire: wire}, frames}
  defp decode(_state, {:error, category}), do: error(category)

  def close(state), do: Mint.HTTP.close(state.conn)
  defp now, do: System.monotonic_time(:millisecond)

  defp error(category),
    do: {:error, %Error{category: category, operation: :terminal, evidence: :dispatch_uncertain}}
end
