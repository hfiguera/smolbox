defmodule SmolBox.CheckpointCapture do
  @moduledoc """
  Durable capture history retained after source deletion. `:captured` proves a
  complete local byte transfer; source and staging quiescence must be confirmed
  before `:completed`. Unknown work is never replayed. Retained artifact disk
  accounting survives completion and machine deletion until explicit release.
  """
  alias SmolBox.{CheckpointCaptureSpec, CheckpointResult, Error, Validation}

  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureTransition,
    NativeCaptureCleanup,
    NativeGrowth,
    Shape
  }

  @enforce_keys [:machine, :spec, :fingerprint, :accepted_at_ms, :updated_at_ms, :deadline_ms]
  @derive {Inspect, only: [:machine, :state, :version]}
  defstruct @enforce_keys ++
              [
                state: :accepted,
                version: 1,
                result: nil,
                error: nil,
                resolved_at_ms: nil,
                released_at_ms: nil,
                native_transition: nil,
                native_source_receipt: nil,
                native_cleanup: nil,
                native_abort_source: nil
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
         true <- result?(r) and native_evidence?(r),
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
        entry_valid?(r, id, m)
      end) and active?(m)
  end

  defp entry_valid?(r, id, m),
    do:
      validate(r) == :ok and r.spec.id == id and
        r.machine == {m.scope, m.id} and source_result?(r, m) and source_enrolled?(r, m) and
        native_fields?(r, m) and
        (terminal?(r) or m.active_capture == id)

  defp native_fields?(_r, %{backend_assignment: %{version: 2}}), do: true

  defp native_fields?(r, _m),
    do:
      r.native_transition == nil and r.native_source_receipt == nil and
        r.native_cleanup == nil and r.native_abort_source == nil

  defp source_enrolled?(%{native_source_receipt: nil}, _), do: true

  defp source_enrolled?(r, %{created_machine: %{backend_identity: %{receipt: origin}}} = m) do
    source = r.native_source_receipt

    receipts =
      [origin] ++
        Enum.flat_map(Map.values(m.captures) ++ Map.values(m.disk_expansions), fn
          %{native_transition: %{receipt: receipt}} -> [receipt]
          _ -> []
        end)

    Shape.receipt?(origin, 2) and Map.delete(source, "material") == Map.delete(origin, "material") and
      source in receipts
  end

  defp source_enrolled?(_, _), do: false

  defp source_result?(%{result: nil}, _), do: true

  defp source_result?(r, %{backend_assignment: %{version: 2}} = m),
    do:
      r.result.profile == NativeGrowth.capture_profile(m, r) and
        r.result.architecture == m.spec.artifact["architecture"]

  defp source_result?(%{result: result}, %{spec: spec}),
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

  defp native_evidence?(r),
    do: native?(r) and native_source?(r) and cleanup?(r) and abort_source?(r)

  defp native_source?(%{native_source_receipt: nil}), do: true

  defp native_source?(r),
    do:
      Shape.receipt?(r.native_source_receipt, 2) and
        (r.native_transition == nil or r.native_transition.previous == r.native_source_receipt)

  defp cleanup?(%{native_cleanup: nil}), do: true

  defp cleanup?(r),
    do:
      r.state in [:completed, :resolved_unknown] and r.released_at_ms != nil and
        NativeCaptureCleanup.bound?(
          r.native_cleanup,
          r,
          r.native_source_receipt || (r.native_transition && r.native_transition.previous)
        )

  defp abort_source?(%{native_abort_source: nil}), do: true

  defp abort_source?(r),
    do:
      r.state == :resolved_unknown and r.result == nil and r.native_transition == nil and
        CaptureAbortSourceQualification.bound?(
          r.native_abort_source,
          r.native_source_receipt,
          r.spec.id,
          %{"max_bytes" => r.spec.policy.max_bytes, "idle" => r.spec.idle}
        ) and
        (r.native_cleanup == nil or
           (r.native_cleanup.kind == :aborted and
              Map.from_struct(r.native_cleanup.receipt)
              |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end) == r.native_abort_source.cleanup))

  defp native?(%{native_transition: nil}), do: true

  defp native?(%{native_transition: %CaptureResolutionTransition{} = transition} = r),
    do:
      r.state == :resolved_unknown and r.result == nil and
        CaptureResolutionTransition.bound?(transition, transition.previous, r.spec.id, %{
          "max_bytes" => r.spec.policy.max_bytes,
          "idle" => r.spec.idle
        })

  defp native?(%{native_transition: transition} = r) do
    CaptureTransition.valid?(transition) and
      r.state in [:captured, :completed, :resolved_unknown] and
      transition.change["intent"]["operation_id"] == r.spec.id and
      transition.change["intent"]["request"] == %{
        "max_bytes" => r.spec.policy.max_bytes,
        "idle" => r.spec.idle
      } and
      (r.result == nil or
         (r.result.sha256 == transition.change["artifact"]["sha256"] and
            r.result.size_bytes == transition.change["artifact"]["size_bytes"]))
  end

  defp key?({scope, id}), do: Validation.identifier?(scope) and Validation.identifier?(id)
  defp key?(_), do: false
end
