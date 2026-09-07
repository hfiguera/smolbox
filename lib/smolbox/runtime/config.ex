defmodule SmolBox.Runtime.Config do
  @moduledoc false
  alias SmolBox.{Error, Identity, Validation}
  alias SmolBox.Runtime.WorkerConfig

  @schema [
    name: [type: :atom, required: true],
    namespace: [type: :string, required: true],
    store: [type: :any, required: true],
    mode: [type: {:in, [:durable, :ephemeral]}, default: :durable],
    fingerprint_key: [type: :string, required: true],
    artifact_store: [type: :any, required: true],
    workers: [type: :any, default: []],
    max_pending: [type: :pos_integer, default: 128],
    max_active: [type: :pos_integer, default: 4],
    poll_ms: [type: :pos_integer, default: 250],
    lease_ms: [type: :pos_integer, default: 30_000],
    cleanup_attempts: [type: :pos_integer, default: 5],
    telemetry_max_pending: [type: :pos_integer, default: 128],
    telemetry_timeout_ms: [type: :pos_integer, default: 100],
    clock: [type: :atom, default: SmolBox.Runtime.Clock]
  ]

  @enforce_keys Keyword.keys(@schema) ++ [:owner]
  @derive {Inspect, only: [:name, :namespace, :mode, :max_pending, :max_active]}
  defstruct Keyword.keys(@schema) ++ [:owner, :telemetry_table]

  @type t :: %__MODULE__{
          name: atom(),
          namespace: String.t(),
          store: {module(), term()},
          mode: :durable | :ephemeral,
          fingerprint_key: binary(),
          artifact_store: {module(), term()},
          workers: [WorkerConfig.t()],
          max_pending: pos_integer(),
          max_active: pos_integer(),
          poll_ms: pos_integer(),
          lease_ms: pos_integer(),
          cleanup_attempts: pos_integer(),
          telemetry_max_pending: pos_integer(),
          telemetry_timeout_ms: pos_integer(),
          telemetry_table: :ets.tid() | nil,
          clock: module(),
          owner: String.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    with true <- Keyword.keyword?(options),
         {:ok, values} <- NimbleOptions.validate(options, @schema),
         {:ok, owner} <- Identity.machine_name("owner"),
         config = struct!(__MODULE__, [{:owner, owner} | values]),
         true <- valid?(config),
         :ok <- persistence(config) do
      {:ok, config}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:validation)
    end
  end

  @spec persistence(t()) :: :ok | {:error, Error.t()}
  def persistence(%{store: {adapter, context}, mode: mode}) do
    case adapter.capabilities(context) do
      {:ok, %{schema: 1, atomic: true, durable: durable}} when is_boolean(durable) ->
        if mode == :ephemeral or durable, do: :ok, else: error(:unsupported_capability)

      _unsupported ->
        error(:store)
    end
  rescue
    _redacted -> error(:store)
  catch
    :exit, _redacted -> error(:store)
  end

  defp valid?(config) do
    config.name not in [nil, true, false] and
      match?({:ok, _name}, Identity.machine_name(config.namespace)) and
      byte_size(config.fingerprint_key) in 32..4096 and
      adapter?(config.store, SmolBox.Store.behaviour_info(:callbacks)) and
      adapter?(config.artifact_store, SmolBox.ArtifactStore.behaviour_info(:callbacks)) and
      bounds?(config) and
      adapter?({config.clock, nil}, now: 0, monotonic: 0) and workers?(config.workers)
  end

  defp bounds?(config) do
    Validation.integer?(config.max_pending, 1, 10_000) and
      Validation.integer?(config.max_active, 1, 64) and
      Validation.integer?(config.poll_ms, 10, 5000) and
      Validation.integer?(config.lease_ms, 1000, 900_000) and
      config.lease_ms >= config.poll_ms * 4 and
      Validation.integer?(config.telemetry_max_pending, 1, 1024) and
      Validation.integer?(config.telemetry_timeout_ms, 1, 1000) and
      Validation.integer?(config.cleanup_attempts, 1, 20)
  end

  defp workers?(workers) do
    Validation.list?(workers, 64) and Enum.all?(workers, &(WorkerConfig.validate(&1) == :ok)) and
      MapSet.size(MapSet.new(workers, & &1.client.worker.id)) == length(workers) and
      MapSet.size(MapSet.new(workers, &{&1.client.worker.base_url, &1.client.worker.unix_socket})) ==
        length(workers)
  end

  defp adapter?({module, _context}, callbacks) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {function, arity} -> function_exported?(module, function, arity) end)
  end

  defp adapter?(_value, _callbacks), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :runtime}}
end
