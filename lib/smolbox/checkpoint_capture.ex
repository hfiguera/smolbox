defmodule SmolBox.CheckpointCapture do
  @moduledoc """
  Durable capture history retained after source deletion. `:captured` proves a
  complete local byte transfer; source and staging quiescence must be confirmed
  before `:completed`. Unknown work is never replayed. Retained artifact disk
  accounting survives completion and machine deletion until explicit release.
  """
  alias SmolBox.{CheckpointCaptureSpec, CheckpointResult, Error, Validation}
  @enforce_keys [:machine, :spec, :fingerprint, :accepted_at_ms, :updated_at_ms, :deadline_ms]
  @derive {Inspect, only: [:machine, :state, :version]}
  defstruct @enforce_keys ++
              [
                state: :accepted,
                version: 1,
                result: nil,
                error: nil,
                resolved_at_ms: nil,
                released_at_ms: nil
              ]

  @type state ::
          :accepted
          | :dispatching
          | :captured
          | :unknown
          | :completed
          | :failed
          | :cancelled
          | :resolved_unknown
  @type handle :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          machine: SmolBox.ManagedMachine.key(),
          spec: CheckpointCaptureSpec.t(),
          fingerprint: String.t(),
          accepted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          deadline_ms: non_neg_integer(),
          state: state(),
          version: pos_integer(),
          result: CheckpointResult.t() | nil,
          error: Error.t() | nil,
          resolved_at_ms: non_neg_integer() | nil,
          released_at_ms: non_neg_integer() | nil
        }
  @terminal [:completed, :failed, :cancelled, :resolved_unknown]

  @doc false
  def new(machine, spec, fingerprint, now),
    do: SmolBox.OperationRecord.new(__MODULE__, machine, spec, fingerprint, now)

  @doc false
  def validate(%__MODULE__{} = r) do
    with true <- Validation.struct_shape?(r, __MODULE__),
         :ok <- CheckpointCaptureSpec.validate(r.spec),
         true <- key?(r.machine) and Validation.digest?(r.fingerprint),
         true <- Validation.integer?(r.version, 1, 9_007_199_254_740_991),
         true <-
           Enum.all?([r.accepted_at_ms, r.updated_at_ms, r.deadline_ms], &Validation.timestamp?/1),
         true <-
           r.updated_at_ms >= r.accepted_at_ms and
             r.deadline_ms == r.accepted_at_ms + r.spec.timeout_ms,
         true <- r.state in (@terminal ++ [:accepted, :dispatching, :captured, :unknown]),
         true <- result?(r),
         true <- SmolBox.ExecutionValidation.error?(r.error),
         true <-
           Enum.all?(
             [r.resolved_at_ms, r.released_at_ms],
             &(is_nil(&1) or Validation.timestamp?(&1))
           ),
         true <- r.state not in [:completed, :resolved_unknown] or r.resolved_at_ms != nil,
         true <- r.released_at_ms == nil or terminal?(r) do
      :ok
    else
      _ -> {:error, %Error{category: :validation, operation: :checkpoint}}
    end
  end

  def validate(_), do: {:error, %Error{category: :validation, operation: :checkpoint}}
  @doc false
  def terminal?(r), do: r.state in @terminal
  @doc false
  def path(r), do: Path.join([r.spec.policy.root, r.fingerprint, "capture.smolcheckpoint"])
  @doc false
  def history_valid?(m) do
    is_map(m.captures) and map_size(m.captures) <= 256 and
      Enum.all?(m.captures, fn {id, r} ->
        validate(r) == :ok and r.spec.id == id and r.machine == {m.scope, m.id} and
          source_result?(r.result, m.spec) and
          (terminal?(r) or m.active_capture == id)
      end) and active?(m)
  end

  defp source_result?(nil, _), do: true

  defp source_result?(result, spec),
    do: result.profile == spec.profile and result.architecture == spec.artifact["architecture"]

  @doc false
  def resources(m),
    do:
      Enum.reduce(m.captures, zero(), fn {_id, r}, total ->
        Map.merge(total, resources_for(r), fn _k, a, b -> a + b end)
      end)

  defp resources_for(%{state: state}) when state in [:failed, :cancelled], do: zero()
  defp resources_for(%{released_at_ms: at}) when not is_nil(at), do: zero()

  defp resources_for(%{state: state} = r) when state in [:completed, :resolved_unknown],
    do: %{zero() | disk_gb: div(r.spec.policy.max_bytes + 1_073_741_823, 1_073_741_824)}

  defp resources_for(r), do: r.spec.policy.resources
  defp zero, do: %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}
  defp active?(%{active_capture: nil, operation: op}), do: op != :capture

  defp active?(m),
    do:
      match?(%__MODULE__{}, m.captures[m.active_capture]) and
        not terminal?(m.captures[m.active_capture]) and m.operation == :capture and
        m.active_execution == nil and
        m.state in [:running, :unknown, :missing, :conflict]

  defp result?(%{state: state, result: nil}), do: state not in [:captured, :completed]

  defp result?(%{state: state, result: %CheckpointResult{} = result} = r),
    do:
      state in [:captured, :completed] and CheckpointResult.validate(result) == :ok and
        result.path == path(r) and result.size_bytes <= r.spec.policy.max_bytes

  defp result?(_), do: false
  defp key?({scope, id}), do: Validation.identifier?(scope) and Validation.identifier?(id)
  defp key?(_), do: false
end
