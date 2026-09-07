defmodule SmolBox do
  @moduledoc """
  Standalone managed sandbox executions over pinned, host-operated SmolVM workers.

  Start a named child with `child_spec/1`. Submit a validated immutable execution
  specification under a host-authorized scope. Acceptance is durable only with a
  conforming durable store. An execution handle is `{scope, execution_id}`; it is
  independent of the submitting process and is not an authorization token.

  `await/3` observes stored evidence and has its own timeout. It never cancels the
  guest. `cancel/3` persists intent; fetch the record to distinguish an observed
  exit, unknown outcome, confirmed termination, and eventual cleanup. No API
  automatically repeats an uncertain command.

  Begin with the [Getting started](getting-started.html) walkthrough. Configure
  the runtime with `child_spec/1`, describe work with `SmolBox.ExecutionSpec.new/1`,
  then call `submit/2`. Use `SmolBox.Client` when your host already manages the
  machine lifecycle and only needs individual worker operations.
  """
  alias SmolBox.{Error, Execution, ExecutionSpec, Runtime, Validation}
  alias SmolBox.Runtime.{Inspection, Session, WorkerConfig}

  @type runtime :: Supervisor.supervisor()
  @type handle :: Execution.key()

  @doc """
  Build a named runtime child for your application's supervision tree.

  Start the store before this child. The artifact adapter is `{module, context}`;
  its context need not be a process. See the complete setup in
  [Getting started](getting-started.html) and [Host integration](host-integration.html).

  Required options:

  | Option | Meaning |
  |---|---|
  | `:name` | An atom used to register this runtime and address the managed API |
  | `:namespace` | Exclusive machine-name prefix: 1–10 lowercase letters/digits, starting with a letter |
  | `:store` | `{adapter_module, context}` implementing `SmolBox.Store` |
  | `:artifact_store` | `{adapter_module, context}` implementing `SmolBox.ArtifactStore` |
  | `:fingerprint_key` | Stable host secret of 32–4096 bytes; keep it across durable restarts |

  Optional options:

  | Option | Default | Meaning |
  |---|---|---|
  | `:workers` | `[]` | Up to 64 `SmolBox.Runtime.WorkerConfig` values with unique worker IDs/endpoints; an empty list permits inspection but cannot admit new work |
  | `:mode` | `:durable` | `:ephemeral` explicitly permits a non-durable store such as `SmolBox.Store.Memory` |
  | `:max_pending` | `128` | Pending-queue bound, 1–10,000 |
  | `:max_active` | `4` | Concurrent runtime work tasks, 1–64; worker reservations separately bound admitted guests |
  | `:poll_ms` | `250` | Scan interval, 10–5000 ms |
  | `:lease_ms` | `30_000` | Ownership lease, 1000–900,000 ms and at least four times `:poll_ms` |
  | `:cleanup_attempts` | `5` | Automatic cleanup-attempt budget, 1–20 |
  | `:telemetry_max_pending` | `128` | Notification bound, 1–1024 |
  | `:telemetry_timeout_ms` | `100` | Handler delivery budget, 1–1000 ms |
  | `:clock` | `SmolBox.Runtime.Clock` | Host clock module matching `SmolBox.Runtime.Clock.now/0` and `SmolBox.Runtime.Clock.monotonic/0`; primarily useful for tests |

  Unknown options are rejected during startup. Stopping the runtime stops
  observers; it does not establish guest termination. Use durable storage when
  execution ownership must survive a controller restart.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options),
    do: %{
      id: {Runtime, Keyword.fetch!(options, :name)},
      start: {Runtime, :start_link, [options]},
      type: :supervisor
    }

  @doc """
  Accept an immutable execution and return `{:ok, {scope, id}}`.

  Acceptance records intent; it does not mean the guest has started or the command
  has succeeded. The same scoped ID and semantic specification return the original
  handle. A changed specification under that ID returns `:identity_conflict`.
  At least one configured worker must support a new specification's exact profile
  and approved artifact; otherwise acceptance returns `:unsupported_capability`.

  Preserve the spec and identity after an ambiguous store/transport failure.
  Inspect or resubmit the same identity to resolve acceptance; a fresh ID can
  authorize another execution. Host code must authorize `spec.scope`.
  """
  @spec submit(runtime(), ExecutionSpec.t()) :: {:ok, handle()} | {:error, Error.t()}
  def submit(runtime, spec) do
    with {:ok, config} <- config(runtime),
         :ok <- ExecutionSpec.validate(spec),
         {:ok, fingerprint} <- ExecutionSpec.fingerprint(spec, config.fingerprint_key) do
      case Session.store(config, :fetch, [{spec.scope, spec.id}]) do
        {:ok, %{fingerprint: ^fingerprint} = record} -> {:ok, Execution.key(record)}
        {:ok, _conflict} -> Session.error(:identity_conflict, :submit)
        {:error, %Error{category: :not_found}} -> accept(config, spec, fingerprint)
        {:error, _error} = error -> error
      end
    end
  end

  defp accept(config, spec, fingerprint) do
    if Enum.any?(config.workers, &WorkerConfig.supports?(&1, spec)) do
      with {:ok, record} <- Execution.new(spec, fingerprint, config.clock.now()),
           {:ok, accepted, _status} <-
             Session.store(config, :accept, [record, config.max_pending]),
           do: {:ok, Execution.key(accepted)}
    else
      Session.error(:unsupported_capability, :submit)
    end
  end

  @doc """
  Read `{:ok, %SmolBox.Execution{}}` for an existing scoped identity.

  Returns a typed `:not_found` error only when the store reports absence.
  This is a read, with no worker command or implicit cancellation. The full record
  includes its specification and output; authorize access and avoid logging it.
  Inspect `state`, `result`, `collection`, `cleanup`, and `reservation` separately.
  """
  @spec fetch(runtime(), String.t(), String.t()) :: SmolBox.Store.result()
  def fetch(runtime, scope, id) do
    with :ok <- key(scope, id),
         {:ok, config} <- config(runtime),
         do: Session.store(config, :fetch, [{scope, id}])
  end

  @doc """
  Persist cancellation intent and return the existing execution handle.

  Repeated calls preserve the first cancellation timestamp. An acknowledgment is
  not proof the VM has stopped. After dispatch, missing exit evidence can remain
  unknown even after confirmed termination. A concurrently observed exit is
  preserved. Use `fetch/3` to follow termination, collection, and cleanup.
  """
  @spec cancel(runtime(), String.t(), String.t()) :: {:ok, handle()} | {:error, Error.t()}
  def cancel(runtime, scope, id) do
    with :ok <- key(scope, id),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Session.store(config, :cancel, [{scope, id}, config.clock.now()]),
         do: {:ok, Execution.key(record)}
  end

  @doc "Schedule existing evidence for observation; this never authorizes command replay."
  @spec reconcile(runtime(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def reconcile(runtime, scope, id) do
    with {:ok, _record} <- fetch(runtime, scope, id) do
      call(runtime, {:reconcile, {scope, id}})
    end
  end

  @doc "Exclude a worker from new admission-task launches; already active work may continue."
  @spec drain_worker(runtime(), String.t()) :: :ok | {:error, Error.t()}
  def drain_worker(runtime, worker_id), do: call(runtime, {:drain, worker_id})

  @doc """
  Read configured workers and their latest controller health/drain observations.

  Results include configured capacity, allocation floor, platform, architecture,
  version, qualification and status. Capacity is declared admission capacity,
  not a live host free-memory/disk measurement. See [Telemetry](telemetry.html).
  """
  @spec workers(runtime()) :: {:ok, [map()]} | {:error, Error.t()}
  def workers(runtime), do: call(runtime, :workers)

  @doc "Read ephemeral notification counters; an epoch change resets them."
  @spec telemetry_stats(runtime()) :: {:ok, map()} | {:error, Error.t()}
  def telemetry_stats(runtime), do: call(runtime, :telemetry_stats)

  @doc """
  Read a bounded page of namespace candidates against stored machine assignments.

  This is an operator API across scopes; hosts must authorize access. It sends
  only a worker list request and store reads. Neither names nor findings authorize
  adoption, stopping, or deletion. `:owned` still relies on weak upstream creation
  evidence and exclusive namespace control. `:untracked`, `:unverified`,
  `:conflict`, and `:cleanup_conflict` require investigation; `:unavailable` is not absence.
  A cleanup conflict can be a concurrent deletion or a possible reappearance;
  these separate worker/store reads cannot establish their chronological order.

  Options are `:limit` (1..100, default 20) and `:cursor` (the previous page's
  `next_cursor`). Pages are fresh observations, not a stable historical snapshot;
  periodic scans should restart at nil. The worker list has a one-second budget;
  store lookups have 500 ms each in groups of at most four. No stdout, code,
  command environment, or artifact content is returned.
  """
  @spec audit_worker(runtime(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def audit_worker(runtime, worker_id, options \\ []) do
    with {:ok, config} <- config(runtime), do: Inspection.page(config, worker_id, options)
  end

  @doc """
  Wait up to `timeout` milliseconds for a terminal or unknown stored outcome.

  `timeout` is 0–900,000 ms. Returns `{:ok, %SmolBox.Execution{}}` for a terminal
  state or `:unknown`, or `{:error, %SmolBox.Error{category: :expired}}` when this
  caller's wait expires. Store and validation errors are returned normally.

  A returned record can have a nonzero command exit, collection failure, or no
  known exit. Cleanup and capacity release may still be pending. This function
  never cancels the command; it is safe to await the same handle again. Use
  `cancel/3` for cancellation and `fetch/3` to inspect continuing cleanup.
  """
  @spec await(runtime(), handle(), non_neg_integer()) :: SmolBox.Store.result()
  def await(runtime, {scope, id}, timeout) do
    if Validation.integer?(timeout, 0, 900_000),
      do: await_until(runtime, scope, id, System.monotonic_time(:millisecond) + timeout),
      else: Session.error(:validation, :runtime)
  end

  def await(_runtime, _handle, _timeout), do: Session.error(:validation, :runtime)

  defp await_until(runtime, scope, id, deadline) do
    with {:ok, record} <- fetch(runtime, scope, id) do
      cond do
        Execution.terminal?(record) or record.state == :unknown ->
          {:ok, record}

        System.monotonic_time(:millisecond) >= deadline ->
          Session.error(:expired, :runtime)

        true ->
          receive do
          after
            25 -> await_until(runtime, scope, id, deadline)
          end
      end
    end
  end

  defp key(scope, id) do
    if Validation.identifier?(scope) and Validation.identifier?(id),
      do: :ok,
      else: Session.error(:validation, :runtime)
  end

  defp config(runtime), do: call(runtime, :config)

  defp call(runtime, message) do
    GenServer.call(Runtime.coordinator(runtime), message, 5000)
  rescue
    _redacted -> Session.error(:unknown, :runtime)
  catch
    :exit, _redacted -> Session.error(:unknown, :runtime)
  end
end
