defmodule SmolBox.Transport.Req do
  @moduledoc """
  Bounded Req/Finch transport with verified TLS and no automatic retries or redirects.

  Response decompression and automatic JSON decoding are disabled. Byte limits
  apply before decoding, including SSE framing bytes and ignored events. All
  requests have an outer operation deadline covering pool checkout, connection,
  body transfer and optional synchronous event delivery. Expiry closes observation;
  it does not stop the guest. Managed cancellation must separately stop the VM.

  Pool configurations are derived only from trusted, bounded worker configuration.
  No global Req defaults are changed. Upstream Req/Finch telemetry is outside
  SmolBox's redaction contract; host exporters must not record their request bodies
  or authorization headers.
  """

  @behaviour SmolBox.Transport
  alias SmolBox.{Error, Worker}
  alias SmolBox.Transport.Capture

  @impl SmolBox.Transport
  def request(worker, request) do
    with :ok <- Worker.validate(worker),
         :ok <- request_size(worker, request) do
      task = Task.async(fn -> perform(worker, request) end)

      case Task.yield(task, worker.operation_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _timeout_or_exit -> failure(:transport)
      end
    end
  end

  defp perform(worker, request) do
    options = [
      method: request.method,
      url: worker.base_url <> request.path,
      body: request.body,
      headers: headers(worker, request),
      retry: false,
      redirect: false,
      raw: true,
      compressed: false,
      finch: finch_options(worker),
      unix_socket: worker.unix_socket,
      into: collector(request)
    ]

    case Req.request(options) do
      {:ok, response} -> finish(response, request)
      {:error, _redacted} -> failure(:transport)
    end
  rescue
    _redacted -> failure(:transport)
  catch
    _kind, _redacted -> failure(:transport)
  end

  defp finch_options(worker) do
    tls = if worker.ca_cert_file, do: [cacertfile: worker.ca_cert_file], else: []
    transport = [timeout: worker.connect_timeout_ms, verify: :verify_peer] ++ tls

    [
      conn_opts: [transport_opts: transport],
      size: 4,
      count: 1,
      pool_timeout: worker.pool_timeout_ms,
      receive_timeout: worker.receive_timeout_ms,
      request_timeout: worker.operation_timeout_ms
    ]
  end

  defp headers(worker, request) do
    headers = [{"content-type", request.content_type}, {"accept", request.accept}]
    if worker.token, do: [{"authorization", "Bearer " <> worker.token} | headers], else: headers
  end

  defp collector(request) do
    fn {:data, data}, {req, response} ->
      capture_request = capture_request(response, request)

      with :ok <- response_status(response, capture_request),
           capture =
             Req.Response.get_private(response, :smolbox_capture, Capture.new(capture_request)),
           {:ok, capture} <- Capture.feed(capture, data) do
        {:cont, {req, Req.Response.put_private(response, :smolbox_capture, capture)}}
      else
        {:error, error} ->
          {:halt, {req, Req.Response.put_private(response, :smolbox_error, error)}}
      end
    end
  end

  defp capture_request(%{status: 409}, request),
    do: %{
      request
      | mode: :buffer,
        accept: "application/json",
        max_bytes: min(request.max_bytes, 4096)
    }

  defp capture_request(_response, request), do: request

  defp finish(response, request) do
    case Req.Response.get_private(response, :smolbox_error) do
      nil ->
        capture_request = capture_request(response, request)

        with :ok <- response_status(response, capture_request),
             {:ok, body} <-
               response
               |> Req.Response.get_private(:smolbox_capture, Capture.new(capture_request))
               |> Capture.finish() do
          finish_status(response.status, body)
        end

      error ->
        {:error, error}
    end
  end

  defp finish_status(409, body) do
    case Jason.decode(body) do
      {:ok, %{"code" => "PORT_IN_USE"}} -> failure(:port_conflict)
      _other -> failure(:identity_conflict)
    end
  end

  defp finish_status(_status, body), do: {:ok, body}

  defp response_status(%{status: status}, _accept) when status in [401, 403],
    do: failure(:authentication)

  defp response_status(%{status: 404}, _accept), do: failure(:not_found)

  defp response_status(%{status: status}, _accept) when status not in [200, 409],
    do: failure(:protocol)

  defp response_status(response, request) do
    content_types = Req.Response.get_header(response, "content-type")
    encodings = Req.Response.get_header(response, "content-encoding")

    if media_type?(content_types, request) and encodings in [[], ["identity"]] do
      :ok
    else
      failure(:protocol)
    end
  end

  # Empty readiness has no representation to decode; proxies may add a media
  # type. Capture still rejects every non-empty body, and encodings stay strict.
  defp media_type?(_types, %{mode: :empty}), do: true

  defp media_type?([type], %{accept: expected}),
    do:
      type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        expected

  defp media_type?(_types, _expected), do: false

  defp request_size(worker, request) do
    if byte_size(request.body) <= worker.max_request_bytes do
      :ok
    else
      {:error, %Error{category: :validation, operation: :request_size}}
    end
  end

  defp failure(category),
    do: {:error, %Error{category: category, operation: :transport, evidence: :dispatch_uncertain}}
end
