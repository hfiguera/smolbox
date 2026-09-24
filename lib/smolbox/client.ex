defmodule SmolBox.Client do
  @moduledoc """
  Low-level typed operations against an explicitly configured smolvm worker.

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

  alias SmolBox.{
    Command,
    Error,
    Files,
    Health,
    LaunchResult,
    Machine,
    MachineSpec,
    Result,
    Validation,
    Worker
  }

  alias SmolBox.Terminal.{Handle, Server, Spec}

  @enforce_keys [:worker]
  @derive {Inspect, only: []}
  defstruct [:worker, transport: SmolBox.Transport.Req]
  @type t :: %__MODULE__{worker: Worker.t(), transport: module()}

  @doc """
  Create a client from validated worker configuration without network I/O.

  The only option is `:transport`, a module implementing `SmolBox.Transport`;
  the default is `SmolBox.Transport.Req`. Client operations return typed
  `SmolBox.Error` values and never automatically retry mutations. For managed
  execution identity, observation and cleanup, use `SmolBox` instead.
  """
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

  @doc """
  Read server-reported health and version as `{:ok, %SmolBox.Health{}}`.

  Missing inventory counts remain `nil`. This observation does not qualify the
  worker's artifacts or isolation; use `readiness/1` for the separate pool probe.
  Managed admission independently requires the pinned version.
  """
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

  @doc """
  Create a machine from an approved prepared artifact on the worker, offline by default.

  Returns creation evidence after matching name, allocations and network policy.
  Checkpoint sources additionally require 1.16.1 or 1.17.0, a created branchable response,
  and offline networking. Captured idle state and immutable source contents are
  operator approvals, not remotely attested by this response.
  An enabled policy requires a 1.16.0, 1.16.1 or 1.17.0 health observation. That preflight and the
  create request share the configured operation timeout.
  Persist intent before this call and creation evidence before further mutations.
  A lost or mismatched response can leave creation uncertain; it does not authorize
  retry or deletion by name. See `SmolBox.MachineSpec.new/3` and the
  [client lifecycle example](client.html).
  """
  @spec create(t(), MachineSpec.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def create(client, spec) do
    with {:ok, wire} <- MachineSpec.to_wire(spec),
         {:ok, client} <- creation_runtime(client, spec),
         {:ok, body} <- json(client, :post, "/api/v1/machines", wire, :create),
         {:ok, created} <- decode_machine(body, spec.name, :create) do
      fields = [:cpus, :memory_mb, :storage_gb, :overlay_gb, :network, :ports]

      if Map.take(created, fields) == Map.take(spec, fields) and
           (spec.source != :checkpoint or
              (created.state == :created and body["branchable"] == true)),
         do: {:ok, created},
         else: error(:protocol, :create, :dispatch_uncertain)
    end
  end

  defp creation_runtime(client, %{workload: %SmolBox.Workload{}}),
    do: creation_runtime_versions(client, ["1.17.0"])

  defp creation_runtime(client, %{source: :checkpoint}),
    do: creation_runtime_versions(client, ["1.16.1", "1.17.0"])

  defp creation_runtime(client, %{ports: [_ | _]}),
    do: creation_runtime_versions(client, ["1.17.0"])

  defp creation_runtime(client, %{network: :offline}), do: {:ok, client}

  defp creation_runtime(client, _spec),
    do: creation_runtime_versions(client, ["1.16.0", "1.16.1", "1.17.0"])

  defp creation_runtime_versions(client, versions) do
    with :ok <- Worker.validate(client.worker) do
      deadline = System.monotonic_time(:millisecond) + client.worker.operation_timeout_ms

      case health(client) do
        {:ok, %{version: version}} ->
          supported_create_budget(client, version in versions, deadline)

        {:error, failure} ->
          {:error, %{failure | operation: :create, evidence: :not_dispatched}}
      end
    end
  end

  defp supported_create_budget(client, true, deadline),
    do: remaining_create_budget(client, deadline)

  defp supported_create_budget(_client, false, _deadline),
    do: error(:unsupported_capability, :create)

  defp remaining_create_budget(client, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: {:ok, %{client | worker: %{client.worker | operation_timeout_ms: remaining}}},
      else: error(:expired, :create)
  end

  @doc """
  Read up to 1024 machine observations from the configured worker.

  All entries must satisfy the supported machine and network contract; an incompatible
  entry fails the result. Listing does not establish ownership or authorize cleanup.
  """
  @spec list(t()) :: {:ok, [Machine.t()]} | {:error, Error.t()}
  def list(client) do
    with {:ok, body} <- json(client, :get, "/api/v1/machines", nil, :list) do
      decode_list(body)
    end
  end

  @doc "Read a named machine without starting it; absence is a typed `:not_found` error."
  @spec inspect_machine(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def inspect_machine(client, name), do: lifecycle(client, name, :get, "", :inspect)
  @doc "Start a machine and return its observation. The caller must establish ownership first."
  @spec start(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def start(client, name), do: lifecycle(client, name, :post, "/start", :start)

  @doc """
  Request a stop while preserving an owned machine's disks, and return its observation.

  This does not recover the command's exit code or fence an earlier delayed exec
  request. The caller must verify the returned state and continue appropriate
  reconciliation. A failed stop can leave the machine running; it does not
  authorize discarding its disks. See [Recovery](recovery.html).
  """
  @spec stop(t(), String.t()) :: {:ok, Machine.t()} | {:error, Error.t()}
  def stop(client, name), do: lifecycle(client, name, :post, "/stop", :stop)

  @doc """
  Terminate and discard an owned machine, validating the worker's deletion acknowledgment.

  Returns `:ok` on a matching acknowledgment. Verify ownership and authorize
  disposal only after collection and any required retention; an earlier successful
  stop is not required. Verify absence afterward with `inspect_machine/2`.
  This low-level operation does not manage retention or release a managed
  execution's reservation.
  """
  @spec delete(t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(client, name) do
    with {:ok, path} <- machine_path(name),
         {:ok, body} <- json(client, :delete, path, nil, :delete) do
      if body == %{"deleted" => name},
        do: :ok,
        else: error(:protocol, :delete, :dispatch_uncertain)
    end
  end

  @doc """
  Execute a command with buffered, byte-preserving stdout and stderr, or launch
  a background process and return `SmolBox.LaunchResult`.

  `:max_output_bytes` defaults to 1 MiB and accepts 1 byte–8 MiB combined output.
  The worker's encoded response cap also applies. Bounded UTF-8 stdin is supported
  through `SmolBox.Command`. A nonzero exit returns `{:ok, %SmolBox.Result{}}`.

  Exec can start a stopped VM. A timeout or lost response does not prove the
  command failed or terminated; never automatically replay an uncertain exec.
  An output-limit error may retain a known foreground exit code; inspect its evidence.
  Background acknowledgment overflow or malformed PID always leaves launch uncertain.
  Extended commands require smolvm 1.17.0; background requires a non-checkpoint
  image machine. Their preflight shares the operation deadline and their receive
  budget follows its remaining time. Background has no guest lifetime timeout.
  See [Long-running execution](long-running-exec.html).
  """
  @spec exec(t(), String.t(), Command.t(), keyword()) ::
          {:ok, Result.t() | LaunchResult.t()} | {:error, Error.t()}
  def exec(client, name, command, options \\ []) do
    with {:ok, max} <- output_options(options, [:max_output_bytes]),
         {:ok, path} <- machine_path(name),
         {:ok, wire} <- Command.to_wire(command),
         :ok <- Worker.validate(client.worker),
         {:ok, client} <- execution_client(client, path, command),
         {:ok, body} <- json(client, :post, path <> "/exec", wire, :exec) do
      if command.background,
        do: LaunchResult.from_wire(body, max),
        else: Result.from_wire(body, max)
    end
  end

  @doc """
  Execute through SSE, returning bounded output with `encoding: :lossy_utf8`.

  Options are `:max_output_bytes` (default 1 MiB, range 1 byte–8 MiB combined) and
  `:on_event`, an optional one-argument function. It receives `{:stdout, text}`,
  `{:stderr, text}`, and `{:exit, integer}` synchronously. A crashing callback is
  detached; a blocked callback consumes the overall operation deadline. Notifications
  are advisory and the encoded response cap includes stream framing.

  Streaming stdin is rejected on the pinned worker; use `exec/4` or files. A lost
  stream is not guest termination. Binary output should use buffered execution.
  """
  @spec exec_stream(t(), String.t(), Command.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def exec_stream(client, name, command, options \\ []) do
    with {:ok, max} <- output_options(options, [:max_output_bytes, :on_event]),
         :ok <- streaming_command(command, options),
         {:ok, path} <- machine_path(name),
         {:ok, wire} <- Command.to_wire(command),
         :ok <- Worker.validate(client.worker),
         {:ok, client} <- execution_client(client, path, command) do
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

  @doc """
  Upload up to 1 MiB of bytes to an exact guest workspace path.

  `sha256` is the lowercase digest from `SmolBox.Files.sha256/1`. The client verifies
  it before sending and checks the worker's path/size acknowledgment. This endpoint
  can start a stopped VM; it is a mutation and must not be blindly retried.
  Permissions and atomic rename are not caller-configurable through this API.
  """
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

  @doc """
  Download one exact guest workspace file, preserving its bytes.

  `max_bytes` is required, from 1 byte through 1 MiB. The smaller of this limit and
  the worker response cap applies. Downloads can start a stopped machine, so they
  are not passive recovery probes. Lexical path checks do not establish symlink
  containment. Managed outputs should be read through the artifact adapter after
  collection, rather than reopening the guest after cleanup.
  """
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
        command.background -> error(:unsupported_capability, :exec_stream)
        not is_nil(command.stdin) -> error(:unsupported_capability, :exec_stream)
        is_nil(options[:on_event]) or is_function(options[:on_event], 1) -> :ok
        true -> error(:validation, :exec_stream)
      end
    end
  end

  @doc """
  Read console diagnostics or follow them with a synchronous `on_event` callback.

  Options: `tail` (0–10,000, default 100), `follow` (false), `timeout_ms`
  (1,000–300,000, default 30,000; also capped by the worker operation budget),
  `max_output_bytes` (1–8 MiB, default 1 MiB), and `on_event` receiving `{:log, line}`.
  Following requires a callback. At most 10,000 events are captured. The worker's
  wire-response and receive limits also apply. No automatic reconnection occurs.

  Requires 1.17.0. A missing log is not proof of an absent machine. This read never
  starts/stops a VM and does not observe workload success. Application stdout and
  stderr are discarded upstream; these are boot/agent console diagnostics.
  """
  @spec logs(t(), String.t(), keyword()) :: {:ok, SmolBox.LogResult.t()} | {:error, Error.t()}
  def logs(client, name, options \\ []) do
    with {:ok, options} <- SmolBox.LogOptions.validate(options),
         {:ok, path} <- machine_path(name),
         :ok <- Worker.validate(client.worker) do
      worker = %{
        client.worker
        | operation_timeout_ms: min(client.worker.operation_timeout_ms, options.timeout_ms)
      }

      client = %{client | worker: worker}

      case creation_runtime_versions(client, ["1.17.0"]) do
        {:ok, client} ->
          query = URI.encode_query(%{"tail" => options.tail, "follow" => options.follow})

          request(
            client,
            :get,
            path <> "/logs?" <> query,
            "",
            "application/json",
            "text/event-stream",
            {:logs, options.max, options.callback},
            :logs
          )

        {:error, error} ->
          {:error, %{error | operation: :logs}}
      end
    end
  end

  @doc "Open a single-consumer interactive terminal. Handshake success is not program readiness."
  @spec open_terminal(t(), String.t(), Spec.t()) ::
          {:ok, Handle.t()} | {:error, Error.t()}
  def open_terminal(client, name, spec) do
    with {:ok, prepared} <- terminal_preflight(client, name, spec),
         do: Server.start(prepared, name, spec, self())
  end

  @doc false
  def terminal_preflight(client, name, spec) do
    budget = min(client.worker.operation_timeout_ms, 30_000)
    client = %{client | worker: %{client.worker | operation_timeout_ms: budget}}
    deadline = System.monotonic_time(:millisecond) + budget

    with true <- client.transport == SmolBox.Transport.Req,
         :ok <- Spec.validate(spec),
         {:ok, path} <- machine_path(name),
         :ok <- Worker.validate(client.worker),
         {:ok, %{version: "1.17.0"}} <- health(client),
         {:ok, client} <- remaining_create_budget(client, deadline),
         :ok <- background_machine(client, path, %{background: true}),
         {:ok, client} <- remaining_create_budget(client, deadline) do
      {:ok, client}
    else
      false -> error(:unsupported_capability, :terminal)
      {:ok, _unsupported} -> error(:unsupported_capability, :terminal)
      {:error, failure} -> {:error, %{failure | operation: :terminal, evidence: :not_dispatched}}
    end
  end

  defp execution_client(client, path, command) do
    if command.background or command.timeout_secs > 300 do
      deadline = System.monotonic_time(:millisecond) + client.worker.operation_timeout_ms

      with {:ok, %{version: "1.17.0"}} <- health(client),
           {:ok, client} <- remaining_create_budget(client, deadline),
           :ok <- background_machine(client, path, command),
           {:ok, client} <- remaining_create_budget(client, deadline) do
        {:ok,
         %{
           client
           | worker: %{client.worker | receive_timeout_ms: client.worker.operation_timeout_ms}
         }}
      else
        {:ok, _unsupported} -> error(:unsupported_capability, :exec)
        {:error, failure} -> {:error, %{failure | operation: :exec, evidence: :not_dispatched}}
      end
    else
      {:ok, client}
    end
  end

  defp background_machine(_client, _path, %{background: false}), do: :ok

  defp background_machine(client, "/api/v1/machines/" <> name = path, _command) do
    with {:ok, body} <- json(client, :get, path, nil, :inspect),
         {:ok, _machine} <- decode_machine(body, name, :inspect) do
      if is_binary(body["image"]) and body["image"] != "" and body["branchable"] == false,
        do: :ok,
        else: error(:unsupported_capability, :exec)
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
