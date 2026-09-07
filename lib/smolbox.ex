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
  """
  alias SmolBox.{Error, Execution, ExecutionSpec, Runtime, Validation}
  alias SmolBox.Runtime.{Inspection, Session, WorkerConfig}

  @type runtime :: Supervisor.supervisor()
  @type handle :: Execution.key()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options),
    do: %{
      id: {Runtime, Keyword.fetch!(options, :name)},
      start: {Runtime, :start_link, [options]},
      type: :supervisor
    }

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

  @spec fetch(runtime(), String.t(), String.t()) :: SmolBox.Store.result()
  def fetch(runtime, scope, id) do
    with :ok <- key(scope, id),
         {:ok, config} <- config(runtime),
         do: Session.store(config, :fetch, [{scope, id}])
  end

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

  @spec workers(runtime()) :: {:ok, [map()]} | {:error, Error.t()}
  def workers(runtime), do: call(runtime, :workers)

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
