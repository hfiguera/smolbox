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
    initial = Capture.new(request)

    fn {:data, data}, {req, response} ->
      with :ok <- response_status(response, request.accept),
           capture = Req.Response.get_private(response, :smolbox_capture, initial),
           {:ok, capture} <- Capture.feed(capture, data) do
        {:cont, {req, Req.Response.put_private(response, :smolbox_capture, capture)}}
      else
        {:error, error} ->
          {:halt, {req, Req.Response.put_private(response, :smolbox_error, error)}}
      end
    end
  end

  defp finish(response, request) do
    case Req.Response.get_private(response, :smolbox_error) do
      nil ->
        with :ok <- response_status(response, request.accept) do
          response
          |> Req.Response.get_private(:smolbox_capture, Capture.new(request))
          |> Capture.finish()
        end

      error ->
        {:error, error}
    end
  end

  defp response_status(%{status: status}, _accept) when status in [401, 403],
    do: failure(:authentication)

  defp response_status(%{status: 404}, _accept), do: failure(:not_found)
  defp response_status(%{status: 409}, _accept), do: failure(:identity_conflict)
  defp response_status(%{status: status}, _accept) when status != 200, do: failure(:protocol)

  defp response_status(response, accept) do
    content_types = Req.Response.get_header(response, "content-type")
    encodings = Req.Response.get_header(response, "content-encoding")

    if media_type?(content_types, accept) and encodings in [[], ["identity"]] do
      :ok
    else
      failure(:protocol)
    end
  end

  defp media_type?([type], expected),
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
