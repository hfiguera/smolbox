defmodule SmolBox.Kubernetes.Client do
  @moduledoc false
  alias SmolBox.Kubernetes.{Credentials, Operation}

  def request(operation, method, path, body \\ nil) do
    with {:ok, body} <- encode(body),
         true <- method in ["GET", "POST", "DELETE"],
         true <-
           is_binary(path) and String.starts_with?(path, "/") and
             not String.starts_with?(path, "//"),
         true <-
           Operation.account(operation, 1, byte_size(body || "")) <=
             operation.budget.max_request_bytes do
      Operation.run(operation, &perform(operation, method, path, body, &1))
    else
      _ -> Operation.error(:validation, operation.name, :not_dispatched)
    end
  end

  defp encode(nil), do: {:ok, nil}
  defp encode(body), do: Jason.encode(body)

  defp perform(operation, method, path, body, sent) do
    with {:ok, token} <-
           Credentials.resolve(operation.config.credential_provider, Operation.budget(operation)),
         true <- Operation.remaining(operation) > 0,
         {:ok, conn} <- connect(operation) do
      try do
        send_request(conn, operation, method, path, body, token, sent)
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, %SmolBox.Error{} = error} -> {:error, %{error | operation: operation.name}}
      _ -> Operation.error(:transport, operation.name, :not_dispatched)
    end
  end

  @doc false
  def connect(operation) do
    uri = URI.parse(operation.config.api_server)

    Mint.HTTP.connect(:https, uri.host, uri.port,
      protocols: [:http1],
      mode: :passive,
      hostname: uri.host,
      max_header_list_size: 16_384,
      transport_opts: [
        cacertfile: operation.config.ca_file,
        verify: :verify_peer,
        timeout: max(1, Operation.remaining(operation)),
        send_timeout: min(1000, max(1, Operation.remaining(operation))),
        send_timeout_close: true,
        buffer: 16_384,
        recbuf: 16_384
      ]
    )
  end

  defp send_request(conn, operation, method, path, body, token, sent) do
    headers = [
      {"authorization", "Bearer " <> token},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]

    Operation.dispatched(sent)

    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        receive_body(conn, ref, operation, %{status: nil, chunks: [], bytes: 0, done: false})

      _ ->
        Operation.error(:transport, operation.name, :dispatch_uncertain)
    end
  end

  defp receive_body(conn, ref, operation, state) do
    if Operation.remaining(operation) == 0 do
      Operation.error(:expired, operation.name, :dispatch_uncertain)
    else
      case Mint.HTTP.recv(conn, 0, max(1, Operation.remaining(operation))) do
        {:ok, conn, events} -> consume(conn, ref, operation, state, events)
        _ -> Operation.error(:transport, operation.name, :dispatch_uncertain)
      end
    end
  end

  defp consume(conn, ref, operation, state, events) do
    case Enum.reduce_while(events, {:ok, state}, &event(&1, &2, ref, operation)) do
      {:ok, %{done: true} = state} -> decode(state, operation)
      {:ok, state} -> receive_body(conn, ref, operation, state)
      error -> error
    end
  end

  defp event({:status, ref, status}, {:ok, state}, ref, operation) do
    if status in 200..299,
      do: {:cont, {:ok, %{state | status: status}}},
      else: {:halt, status_error(status, operation)}
  end

  defp event({:headers, ref, headers}, {:ok, state}, ref, operation) do
    if oversized?(headers, Operation.response_left(operation)),
      do: {:halt, Operation.error(:output_limit, operation.name, :dispatch_uncertain)},
      else: {:cont, {:ok, state}}
  end

  defp event({:data, ref, data}, {:ok, state}, ref, operation) do
    bytes = state.bytes + byte_size(data)

    if Operation.account(operation, 2, byte_size(data)) <= operation.budget.max_response_bytes,
      do: {:cont, {:ok, %{state | bytes: bytes, chunks: [data | state.chunks]}}},
      else: {:halt, Operation.error(:output_limit, operation.name, :dispatch_uncertain)}
  end

  defp event({:done, ref}, {:ok, state}, ref, _), do: {:cont, {:ok, %{state | done: true}}}

  defp event(_, _, _, operation),
    do: {:halt, Operation.error(:protocol, operation.name, :dispatch_uncertain)}

  defp oversized?(headers, max),
    do:
      Enum.any?(headers, fn
        {"content-length", value} ->
          case Integer.parse(value) do
            {size, ""} -> size < 0 or size > max
            _ -> true
          end

        {"content-encoding", value} ->
          value != "identity"

        _ ->
          false
      end)

  defp decode(%{status: 204, bytes: 0}, _operation), do: {:ok, %{}}

  defp decode(state, operation) do
    case state.chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
    end
  end

  defp status_error(status, operation) do
    {category, evidence} =
      case status do
        code when code in [401, 403] -> {:authentication, :not_dispatched}
        404 -> {:not_found, :not_dispatched}
        409 -> {:identity_conflict, :not_dispatched}
        429 -> {:admission_exhausted, :not_dispatched}
        code when code in [400, 422] -> {:validation, :not_dispatched}
        _ -> {:protocol, :dispatch_uncertain}
      end

    Operation.error(category, operation.name, evidence)
  end
end
