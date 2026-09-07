defmodule SmolBox.Runtime.Session do
  @moduledoc false
  alias SmolBox.{Error, Execution, Telemetry}
  alias SmolBox.Runtime.{Config, WorkerConfig}

  @enforce_keys [:config, :key, :worker, :wall, :monotonic]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          config: Config.t(),
          key: Execution.key(),
          worker: WorkerConfig.t() | nil,
          wall: non_neg_integer(),
          monotonic: integer()
        }

  @spec new(Config.t(), Execution.t()) :: t()
  def new(config, record) do
    %__MODULE__{
      config: config,
      key: Execution.key(record),
      worker: Enum.find(config.workers, &(&1.client.worker.id == record.worker_id)),
      wall: config.clock.now(),
      monotonic: config.clock.monotonic()
    }
  end

  @spec now(t()) :: non_neg_integer()
  def now(session), do: session.config.clock.now()

  @spec claim(t()) :: SmolBox.Store.result()
  def claim(session),
    do:
      store(session.config, :claim, [
        session.key,
        session.config.owner,
        now(session),
        session.config.lease_ms
      ])

  @spec write(t(), Execution.t(), keyword()) :: SmolBox.Store.result()
  def write(session, record, changes),
    do:
      store(session.config, :write, [
        session.key,
        guard(record),
        changes,
        max(now(session), record.updated_at_ms)
      ])

  @spec guard(Execution.t()) :: SmolBox.Store.guard()
  def guard(record),
    do: %{owner: record.claim_owner, generation: record.generation, version: record.version}

  @spec store(Config.t(), atom(), list()) :: term()
  def store(%{store: {adapter, context}} = config, operation, arguments) do
    result = call_store(adapter, context, operation, arguments)
    Telemetry.store_result(Map.get(config, :telemetry_table), operation, arguments, result)
    result
  end

  defp call_store(adapter, context, operation, arguments) do
    apply(adapter, operation, [context | arguments])
  rescue
    _redacted -> error(:store, :store)
  catch
    :exit, _redacted -> error(:store, :store)
  end

  @spec remaining(t(), Execution.t(), atom()) :: integer()
  def remaining(session, record, stage),
    do:
      Map.fetch!(record.deadlines, stage) -
        max(now(session), session.wall + session.config.clock.monotonic() - session.monotonic)

  @spec patch(t(), keyword(), non_neg_integer()) :: SmolBox.Store.result()
  def patch(session, changes, retries \\ 2) do
    with {:ok, record} <- claim(session) do
      case write(session, record, changes) do
        {:error, %Error{category: :stale_version}} when retries > 0 ->
          patch(session, changes, retries - 1)

        result ->
          result
      end
    end
  end

  @spec io(t(), Execution.t(), atom(), (-> term())) :: term()
  def io(session, record, stage, function) do
    if remaining(session, record, stage) > 0 do
      task = Task.async(fn -> safe(function) end)

      try do
        observe_io(session, record, stage, task)
      after
        Task.shutdown(task, :brutal_kill)
      end
    else
      error(:expired, :runtime)
    end
  end

  defp observe_io(session, record, stage, task) do
    budget = remaining(session, record, stage)

    cond do
      budget <= 0 ->
        error(:expired, :runtime)

      stage != :cleanup and record.cancel_requested_at_ms != nil ->
        error(:expired, :runtime)

      true ->
        case Task.yield(task, min(budget, session.config.poll_ms)) do
          {:ok, result} ->
            result

          nil ->
            resume_io(session, stage, task)

          _lost ->
            error(:unknown, :runtime)
        end
    end
  end

  defp resume_io(session, stage, task) do
    with {:ok, current} <- claim(session), do: observe_io(session, current, stage, task)
  end

  @spec safe((-> term())) :: term()
  def safe(function) do
    function.()
  rescue
    _redacted -> error(:unknown, :runtime)
  catch
    _kind, _redacted -> error(:unknown, :runtime)
  end

  @spec error(Error.category(), atom()) :: {:error, Error.t()}
  def error(category, operation), do: {:error, %Error{category: category, operation: operation}}
end
