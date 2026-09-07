defmodule SmolBox.Telemetry do
  @moduledoc """
  Redacted, optional managed-runtime observations through `:telemetry`.

  Notifications are asynchronous and bounded. They are not a durable event log,
  an execution receipt, or an acknowledgment from an exporter. Events may be
  dropped, repeated, or missing their matching stage stop after interruption.
  Stored execution evidence remains authoritative. Handlers run in separate
  processes with a deadline; ordinary slow/failing handlers do not run in the
  execution process. Handlers are trusted host code, not sandboxed code.

  Execution metadata contains the configured runtime and namespace, bounded
  scope/execution/worker identifiers and
  finite state/evidence/collection/cleanup categories. Identifiers belong in
  protected traces, never metric labels. Events omit specifications, commands,
  environment, fingerprints, artifact paths, contents, stdout/stderr and raw
  errors. Numeric output sizes and exit codes are measurements, not labels.
  Third-party transport instrumentation and exporter logging are outside this
  payload contract.

  Stage durations use monotonic milliseconds for the current controller attempt.
  Cleanup attempts exclude time spent waiting between reconciliations or during
  evidence retention. Queue wait uses persisted wall-clock timestamps and needs
  the host's documented clock discipline. Notifications can complete out of order
  across producers; use stored versions for inspection, not workflow decisions.
  """

  alias SmolBox.{Error, Execution, Validation}
  alias SmolBox.Telemetry.Dispatcher

  @execution_events [:accepted, :reserved, :updated, :cancel_requested, :released]
  @stages [:preparation, :execution, :collection, :cleanup]
  @states [
    :accepted,
    :preparing,
    :ready,
    :dispatching,
    :running,
    :collecting,
    :completed,
    :collection_failed,
    :failed,
    :cancelled,
    :expired,
    :unknown,
    :cancelling
  ]
  @evidence [
    :not_dispatched,
    :dispatch_uncertain,
    :running_observed,
    :exited,
    :termination_confirmed,
    :unknown
  ]
  @categories [
    :validation,
    :unsupported_capability,
    :authentication,
    :admission_exhausted,
    :expired,
    :transport,
    :protocol,
    :output_limit,
    :identity_conflict,
    :not_found,
    :store,
    :stale_claim,
    :stale_version,
    :unknown,
    :cleanup
  ]
  @changes [
    :state,
    :evidence,
    :result,
    :collection,
    :cleanup,
    :artifacts,
    :last_error,
    :absence_at_ms
  ]

  @spec events() :: [[atom()]]
  def events do
    Enum.map(@execution_events, &[:smolbox, :execution, &1]) ++
      [
        [:smolbox, :stage, :start],
        [:smolbox, :stage, :stop],
        [:smolbox, :worker, :status],
        [:smolbox, :store, :error]
      ]
  end

  @doc false
  @spec store_result(Dispatcher.table() | nil, atom(), list(), term()) :: :ok
  def store_result(table, operation, arguments, result) do
    safe(fn -> stored(table, operation, arguments, result) end)
  end

  defp stored(table, :accept, _arguments, {:ok, record, :inserted}),
    do: execution(table, :accepted, record)

  defp stored(table, operation, _arguments, {:ok, record})
       when operation in [:reserve, :cancel, :release] do
    kind = %{reserve: :reserved, cancel: :cancel_requested, release: :released}[operation]
    execution(table, kind, record)
  end

  defp stored(table, :write, [_key, _guard, changes, _time], {:ok, record}) do
    if Enum.any?(@changes, &Keyword.has_key?(changes, &1)),
      do: execution(table, :updated, record)
  end

  defp stored(table, operation, _arguments, {:error, %Error{category: category}}) do
    if operation in [
         :accept,
         :fetch,
         :find_machine,
         :claim_worker,
         :claim,
         :write,
         :reserve,
         :release,
         :cancel,
         :due,
         :usage,
         :capabilities
       ] do
      offer(
        table,
        {[:smolbox, :store, :error], %{count: 1},
         %{operation: operation, category: category(category)}}
      )
    end
  end

  defp stored(_table, _operation, _arguments, _result), do: :ok

  defp execution(table, kind, %Execution{} = record) do
    with true <- record.state in @states and record.evidence in @evidence,
         true <- record.collection in [:pending, :complete, :partial, :failed],
         true <- record.cleanup in [:pending, :in_progress, :complete, :failed],
         true <- record.worker_id == nil or Validation.identifier?(record.worker_id),
         {:ok, identity} <- identity(Execution.key(record)) do
      metadata =
        Map.merge(
          identity,
          Map.take(record, [:worker_id, :state, :evidence, :collection, :cleanup])
        )

      measurements = %{
        count: 1,
        version: record.version,
        observed_at_ms: record.updated_at_ms,
        age_ms: max(0, record.updated_at_ms - record.accepted_at_ms)
      }

      measurements =
        if kind == :reserved,
          do: Map.put(measurements, :queue_wait_ms, measurements.age_ms),
          else: measurements

      measurements = Map.merge(measurements, result_measurements(record.result))
      measurements = Map.merge(measurements, reservation_measurements(record.reservation))
      measurements = cancellation_measurement(measurements, record.cancel_requested_at_ms)
      offer(table, {[:smolbox, :execution, kind], measurements, metadata})
    end
  end

  defp cancellation_measurement(measurements, nil), do: measurements

  defp cancellation_measurement(measurements, timestamp),
    do: Map.put(measurements, :cancel_requested_at_ms, timestamp)

  defp reservation_measurements(reservation) do
    resources = reservation || %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}

    %{
      reserved_slots: resources.slots,
      reserved_cpus: resources.cpus,
      reserved_memory_mb: resources.memory_mb,
      reserved_disk_gb: resources.disk_gb
    }
  end

  defp result_measurements(nil), do: %{}

  defp result_measurements(result),
    do: %{
      exit_code: result.exit_code,
      stdout_bytes: byte_size(result.stdout),
      stderr_bytes: byte_size(result.stderr),
      truncated: if(result.truncated, do: 1, else: 0)
    }

  @doc false
  @spec span(Dispatcher.table() | nil, atom(), Execution.key(), (-> term())) :: term()
  def span(table, stage, key, function) do
    started = System.monotonic_time(:millisecond)

    stage_event(
      table,
      :start,
      stage,
      key,
      %{system_time_ms: System.system_time(:millisecond)},
      :pending
    )

    try do
      result = function.()
      stage_event(table, :stop, stage, key, %{duration_ms: elapsed(started)}, outcome(result))
      result
    rescue
      error ->
        stage_event(table, :stop, stage, key, %{duration_ms: elapsed(started)}, :exception)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        stage_event(table, :stop, stage, key, %{duration_ms: elapsed(started)}, :exception)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp stage_event(table, event, stage, key, measurements, outcome) do
    safe(fn ->
      with true <- stage in @stages, {:ok, identity} <- identity(key) do
        metadata = Map.merge(identity, %{stage: stage, outcome: outcome})
        offer(table, {[:smolbox, :stage, event], measurements, metadata})
      end
    end)
  end

  @doc false
  @spec worker(Dispatcher.table() | nil, SmolBox.Runtime.WorkerConfig.t(), atom()) :: :ok
  def worker(table, worker, status) do
    safe(fn ->
      if status in [:ready, :degraded, :incompatible, :unavailable, :draining] and
           worker.platform in [:linux, :macos] and Validation.identifier?(worker.client.worker.id) do
        offer(
          table,
          {[:smolbox, :worker, :status], %{count: 1},
           %{worker_id: worker.client.worker.id, platform: worker.platform, status: status}}
        )
      end
    end)
  end

  defp offer(table, {_name, measurements, _metadata} = event) do
    if Enum.all?(
         Map.values(measurements),
         &Validation.integer?(&1, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807)
       ) and
         :erlang.external_size(event) <= 4096 do
      Dispatcher.offer(table, event)
    end
  end

  defp identity({scope, id}) do
    if Validation.identifier?(scope) and Validation.identifier?(id),
      do: {:ok, %{scope: scope, execution_id: id}},
      else: :error
  end

  defp identity(_key), do: :error
  defp elapsed(started), do: max(0, System.monotonic_time(:millisecond) - started)
  defp category(value), do: if(value in @categories, do: value, else: :unknown)
  defp outcome({:error, _error}), do: :error
  defp outcome(_result), do: :returned

  defp safe(function) do
    function.()
    :ok
  rescue
    _redacted -> :ok
  catch
    _kind, _redacted -> :ok
  end
end
