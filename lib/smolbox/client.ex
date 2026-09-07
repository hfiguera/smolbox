defmodule SmolBox.Client do
  @moduledoc """
  Low-level typed operations against an explicitly configured SmolVM worker.

  This API does not persist execution identity or authorize cleanup. Callers own
  machine ownership checks, admission, deadlines, and recovery. No operation is
  automatically retried. In particular, both exec and file transfers may start a
  stopped machine upstream; never use them as observational recovery probes.

  Streaming captures bounded lossy UTF-8 and optionally delivers synchronous
  events with backpressure. A crashing callback is detached. A blocking callback
  is bounded by the overall operation deadline. Neither disconnect nor output
  overflow implies termination; explicitly stop an owned VM and inspect it.

  File transfers preserve bytes. Upload verifies the source digest before any I/O
  and checks the worker's acknowledgment, but upstream supplies no atomic rename
  or permission parameter. Managed preparation must verify completion before exec.
  Path validation is lexical; the API does not provide race-free workspace-only
  symlink containment inside an untrusted guest. No archive extraction is done.
  """

  alias SmolBox.{Command, Error, Files, Health, Machine, MachineSpec, Result, Validation, Worker}

  @enforce_keys [:worker]
  @derive {Inspect, only: []}
  defstruct [:worker, transport: SmolBox.Transport.Req]
  @type t :: %__MODULE__{worker: Worker.t(), transport: module()}

  @spec new(Worker.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(worker, options \\ []) do
    with :ok <- Worker.validate(worker),
         true <- Validation.keys?(options, [:transport]),
         transport = Keyword.get(options, :transport, SmolBox.Transport.Req),
         true <-
           is_atom(transport) and Code.ensure_loaded?(transport) and
             function_exported?(transport, :request, 2) do
      {:ok, %__MODULE__{worker: worker, transport: transport}}
    else
      _invalid -> error(:validation, :client)
    end
  end

  @spec health(t()) :: {:ok, Health.t()} | {:error, Error.t()}
  def health(client) do
    with {:ok, body} <- json(client, :get, "/health", nil, :health),
         do: Health.from_wire(body)
  end

  @doc "Checks the upstream blocking-pool probe; requires HTTP 200 with an empty body."
  @spec readiness(t()) :: :ok | {:error, Error.t()}
  def readiness(client) do
    case request(client, :get, "/readyz", "", "application/json", "*/*", :empty, :readiness) do
      {:ok, ""} -> :ok
      {:ok, _invalid} -> error(:protocol, :readiness)
      {:error, _error} = error -> error
    end
  end

  @spec create(t(), MachineSpec.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def create(client, spec) do
    with {:ok, wire} <- MachineSpec.to_wire(spec),
         {:ok, body} <- json(client, :post, "/api/v1/machines", wire, :create),
         {:ok, created} <- decode_machine(body, spec.name, :create) do
      fields = [:cpus, :memory_mb, :storage_gb, :overlay_gb]

      if Map.take(created, fields) == Map.take(spec, fields),
        do: {:ok, created},
        else: error(:protocol, :create, :dispatch_uncertain)
    end
  end

  @spec list(t()) :: {:ok, [Machine.t()]} | {:error, Error.t()}
  def list(client) do
    with {:ok, body} <- json(client, :get, "/api/v1/machines", nil, :list) do
      decode_list(body)
    end
  end

  @spec inspect_machine(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def inspect_machine(client, name), do: lifecycle(client, name, :get, "", :inspect)
  @spec start(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def start(client, name), do: lifecycle(client, name, :post, "/start", :start)
  @spec stop(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def stop(client, name), do: lifecycle(client, name, :post, "/stop", :stop)

  @spec delete(t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(client, name) do
    with {:ok, path} <- machine_path(name),
         {:ok, body} <- json(client, :delete, path, nil, :delete) do
      if body == %{"deleted" => name},
        do: :ok,
        else: error(:protocol, :delete, :dispatch_uncertain)
    end
  end

  @spec exec(t(), String.t(), Command.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def exec(client, name, command, options \\ []) do
    with {:ok, max} <- output_options(options, [:max_output_bytes]),
         {:ok, path} <- machine_path(name),
         {:ok, wire} <- Command.to_wire(command),
         {:ok, body} <- json(client, :post, path <> "/exec", wire, :exec) do
      Result.from_wire(body, max)
    end
  end

  @spec exec_stream(t(), String.t(), Command.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def exec_stream(client, name, command, options \\ []) do
    with {:ok, max} <- output_options(options, [:max_output_bytes, :on_event]),
         :ok <- streaming_command(command, options),
         {:ok, path} <- machine_path(name),
         {:ok, wire} <- Command.to_wire(command) do
      mode = {:sse, max, Keyword.get(options, :on_event)}

      request(
        client,
        :post,
        path <> "/exec/stream",
        Jason.encode!(wire),
        "application/json",
        "text/event-stream",
        mode,
        :exec_stream
      )
    end
  end

  @spec upload(t(), String.t(), String.t(), binary(), String.t()) :: :ok | {:error, Error.t()}
  def upload(client, name, guest_path, bytes, sha256) do
    with :ok <- input_bytes(bytes, sha256),
         {:ok, path} <- file_path(name, guest_path),
         {:ok, body} <-
           request(
             client,
             :put,
             path,
             bytes,
             "application/octet-stream",
             "application/json",
             :buffer,
             :upload
           ),
         {:ok, decoded} <- decode_json(body, :upload) do
      case decoded do
        %{"path" => ^guest_path, "size" => size} when size == byte_size(bytes) -> :ok
        _invalid -> error(:protocol, :upload, :dispatch_uncertain)
      end
    end
  end

  @spec download(t(), String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def download(client, name, guest_path, max_bytes) do
    with true <- Validation.integer?(max_bytes, 1, 1_048_576),
         {:ok, path} <- file_path(name, guest_path) do
      bounded = %{
        client
        | worker: %{
            client.worker
            | max_response_bytes: min(max_bytes, client.worker.max_response_bytes)
          }
      }

      request(
        bounded,
        :get,
        path,
        "",
        "application/octet-stream",
        "application/octet-stream",
        :buffer,
        :download
      )
    else
      false -> error(:validation, :download)
      {:error, _error} = error -> error
    end
  end

  defp lifecycle(client, name, method, suffix, operation) do
    wire = if method == :post, do: %{}, else: nil

    with {:ok, path} <- machine_path(name),
         {:ok, body} <- json(client, method, path <> suffix, wire, operation) do
      decode_machine(body, name, operation)
    end
  end

  defp decode_machine(body, expected, operation) do
    case Machine.from_wire(body) do
      {:ok, machine} ->
        if machine.name == expected,
          do: {:ok, machine},
          else: error(:identity_conflict, operation, :dispatch_uncertain)

      {:error, error} ->
        {:error, %{error | operation: operation, evidence: :dispatch_uncertain}}
    end
  end

  defp decode_list(%{"machines" => body}) when is_list(body) do
    if Validation.list?(body, 1024) do
      Enum.reduce_while(body, {:ok, []}, &decode_entry/2)
      |> case do
        {:ok, machines} -> {:ok, Enum.reverse(machines)}
        error -> error
      end
    else
      error(:output_limit, :list)
    end
  end

  defp decode_list(_body), do: error(:protocol, :list)

  defp decode_entry(entry, {:ok, acc}) do
    case Machine.from_wire(entry) do
      {:ok, machine} -> {:cont, {:ok, [machine | acc]}}
      {:error, _error} = error -> {:halt, error}
    end
  end

  defp json(client, method, path, wire, operation) do
    encoded = if is_nil(wire), do: "", else: Jason.encode!(wire)

    with {:ok, body} <-
           request(
             client,
             method,
             path,
             encoded,
             "application/json",
             "application/json",
             :buffer,
             operation
           ) do
      decode_json(body, operation)
    end
  end

  defp decode_json(body, operation) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _redacted} -> error(:protocol, operation, :dispatch_uncertain)
    end
  end

  defp request(client, method, path, body, content_type, accept, mode, operation) do
    request = %{
      method: method,
      path: path,
      body: body,
      content_type: content_type,
      accept: accept,
      mode: mode,
      max_bytes: client.worker.max_response_bytes
    }

    case client.transport.request(client.worker, request) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, %{error | operation: operation}}
    end
  end

  defp output_options(options, allowed) do
    if Validation.keys?(options, allowed) and
         Validation.integer?(Keyword.get(options, :max_output_bytes, 1_048_576), 1, 8_388_608) do
      {:ok, Keyword.get(options, :max_output_bytes, 1_048_576)}
    else
      error(:validation, :exec_options)
    end
  end

  defp streaming_command(command, options) do
    with :ok <- Command.validate(command) do
      cond do
        not is_nil(command.stdin) -> error(:unsupported_capability, :exec_stream)
        is_nil(options[:on_event]) or is_function(options[:on_event], 1) -> :ok
        true -> error(:validation, :exec_stream)
      end
    end
  end

  defp input_bytes(bytes, digest) do
    if is_binary(bytes) and byte_size(bytes) <= 1_048_576 and Validation.digest?(digest) and
         Files.sha256(bytes) == digest do
      :ok
    else
      error(:validation, :upload)
    end
  end

  defp file_path(name, guest_path) do
    with {:ok, path} <- machine_path(name), {:ok, encoded} <- Files.encode_path(guest_path) do
      {:ok, path <> "/files/" <> encoded}
    end
  end

  defp machine_path(name) do
    if MachineSpec.valid_name?(name),
      do: {:ok, "/api/v1/machines/" <> name},
      else: error(:validation, :machine_name)
  end

  defp error(category, operation, evidence \\ :not_dispatched),
    do: {:error, %Error{category: category, operation: operation, evidence: evidence}}
end
