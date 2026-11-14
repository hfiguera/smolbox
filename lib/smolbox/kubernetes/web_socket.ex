defmodule SmolBox.Kubernetes.WebSocket do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Kubernetes.{Client, Credentials, GuestHelper, Operation, RemoteCommand}
  alias SmolBox.WebSocket.Wire

  @protocol "v5.channel.k8s.io"
  def protocol, do: @protocol

  def path(receipt) do
    query =
      [
        {"container", "workload"},
        {"stdin", "true"},
        {"stdout", "true"},
        {"stderr", "true"},
        {"tty", "false"}
      ] ++
        Enum.map(GuestHelper.argv(), &{"command", &1})

    "/api/v1/namespaces/" <>
      receipt.binding.namespace <>
      "/pods/" <> receipt.pod_name <> "/exec?" <> URI.encode_query(query)
  end

  # The outer operation owns the snapshot table. Preserve qualified output/exit
  # even if this socket owner is killed while a synchronous callback stalls.
  def run(operation, receipt, payload, snapshot, callback, sent) do
    with {:ok, token} <-
           Credentials.resolve(operation.config.credential_provider, Operation.budget(operation)),
         {:ok, conn} <- Client.connect(operation) do
      try do
        Operation.dispatched(sent)
        headers = [{"authorization", "Bearer " <> token}, {"sec-websocket-protocol", @protocol}]

        with {:ok, conn, ref} <-
               Mint.WebSocket.upgrade(:wss, conn, path(receipt), headers, extensions: []),
             {:ok, conn, ws} <-
               upgrade(operation, conn, ref, %{status: nil, headers: [], done: false}, 0) do
          state = %{
            conn: conn,
            ref: ref,
            wire: Wire.new(ws, 1_048_577),
            input: payload,
            operation: operation,
            snapshot: snapshot,
            callback: callback
          }

          pump(state)
        else
          {:error, category} -> {:error, category}
          _ -> {:error, :transport}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, %Error{} = error} ->
        {:error, %{error | operation: operation.name, evidence: :not_dispatched}}

      _ ->
        Operation.error(:transport, operation.name, :not_dispatched)
    end
  end

  defp upgrade(operation, conn, ref, state, bytes) do
    if Operation.remaining(operation) == 0 or bytes >= 16_384 do
      {:error, :expired}
    else
      case Mint.HTTP.recv(conn, 1, max(1, Operation.remaining(operation))) do
        {:ok, conn, events} ->
          next = Enum.reduce(events, state, &upgrade_event(&1, &2, ref))
          upgrade_account(operation, conn, ref, next, bytes + 1)

        _ ->
          {:error, :transport}
      end
    end
  end

  defp upgrade_account(operation, conn, ref, state, bytes) do
    if Operation.account(operation, 2, 1) <= operation.budget.max_response_bytes,
      do: upgrade_next(operation, conn, ref, state, bytes),
      else: {:error, :output_limit}
  end

  defp upgrade_event({:status, ref, status}, state, ref), do: %{state | status: status}

  defp upgrade_event({:headers, ref, headers}, state, ref),
    do: %{state | headers: state.headers ++ headers}

  defp upgrade_event({:done, ref}, state, ref), do: %{state | done: true}
  defp upgrade_event(_, state, _), do: %{state | status: :invalid}

  defp upgrade_next(operation, conn, ref, state, bytes) do
    cond do
      state.status in [401, 403] ->
        Operation.error(:authentication, operation.name, :not_dispatched)

      state.status not in [nil, 101] ->
        {:error, :protocol}

      not state.done ->
        upgrade(operation, conn, ref, state, bytes)

      not negotiated?(state.headers) ->
        {:error, :protocol}

      true ->
        case Mint.WebSocket.new(conn, ref, 101, state.headers, mode: :passive) do
          {:ok, conn, ws} -> {:ok, conn, ws}
          _ -> {:error, :protocol}
        end
    end
  end

  defp negotiated?(headers) do
    selected = for {"sec-websocket-protocol", value} <- headers, do: value
    extensions = for {"sec-websocket-extensions", value} <- headers, do: value
    upgrade = for {"upgrade", value} <- headers, do: String.downcase(value)
    connection = for {"connection", value} <- headers, do: String.downcase(value)

    selected == [@protocol] and extensions == [] and upgrade == ["websocket"] and
      Enum.any?(connection, &("upgrade" in String.split(&1, ~r/\s*,\s*/)))
  end

  defp pump(state) do
    with true <- Operation.remaining(state.operation) > 0,
         {:ok, state} <- produce(state) do
      receive_frames(state)
    else
      false -> {:error, :expired}
      error -> error
    end
  end

  defp produce(%{input: <<>>} = state), do: {:ok, state}

  defp produce(state) do
    count = min(byte_size(state.input), 16_384)
    <<chunk::binary-size(^count), rest::binary>> = state.input

    with {:ok, state} <- send_frame(state, {:binary, <<0, chunk::binary>>}),
         do: {:ok, %{state | input: rest}}
  end

  defp send_frame(state, frame) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(state.wire.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes),
         do: {:ok, %{state | conn: conn, wire: %{state.wire | ws: ws}}},
         else: (_ -> {:error, :transport})
  end

  defp receive_frames(state) do
    timeout = if state.input == "", do: min(50, Operation.remaining(state.operation)), else: 0
    socket = Mint.HTTP.get_socket(state.conn)

    case :ssl.recv(socket, 0, timeout) do
      {:ok, bytes} ->
        if Operation.account(state.operation, 2, byte_size(bytes)) <=
             state.operation.budget.max_response_bytes,
           do: wire_frames(state, Wire.feed(state.wire, bytes)),
           else: {:error, :output_limit}

      {:error, :timeout} ->
        pump(state)

      _ ->
        {:error, :transport}
    end
  end

  defp wire_frames(state, {:ok, wire, frames}) do
    with {:ok, state} <- apply_frames(%{state | wire: wire}, frames) do
      command = snapshot(state.snapshot)

      wire_next(state, command.closed)
    end
  end

  defp wire_frames(_, {:error, category}), do: {:error, category}

  defp wire_next(state, false), do: pump(state)
  defp wire_next(%{wire: %{buffer: "", message_bytes: 0}, input: ""}, true), do: :ok
  defp wire_next(_, true), do: {:error, :protocol}

  defp apply_frames(state, []), do: {:ok, state}

  defp apply_frames(state, [frame | rest]) do
    current = snapshot(state.snapshot)

    case RemoteCommand.feed(current, frame) do
      {:ok, next, events} ->
        :ets.insert(state.snapshot, {:capture, next})
        with {:ok, state} <- deliver(state, events), do: apply_frames(state, rest)

      {:error, category, next, events} ->
        :ets.insert(state.snapshot, {:capture, next})
        deliver(state, events)
        {:error, category}
    end
  end

  defp deliver(state, []), do: {:ok, state}

  defp deliver(state, [{:pong, data} | rest]) do
    with {:ok, state} <- send_frame(state, {:pong, data}), do: deliver(state, rest)
  end

  defp deliver(state, [event | rest]) do
    if state.callback, do: state.callback.(event)
    deliver(state, rest)
  end

  def snapshot(table), do: :ets.lookup_element(table, :capture, 2)
end
