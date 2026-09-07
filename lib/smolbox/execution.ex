defmodule SmolBox.Execution do
  @moduledoc """
  Versioned persisted execution evidence, independent of caller processes.

  State, execution evidence, collection, and cleanup are separate dimensions.
  Versioned store operations are the authority; this module only validates and
  transforms records. A transition never sends a worker request. Dispatching may
  advance directly to collecting when buffered exec returns a known exit.

  Absolute stage deadlines are set on first entry and never reset by observation
  or restart. Uncertain execution can have confirmed termination and completed
  cleanup while its original command outcome remains unknown.
  """

  alias SmolBox.{Error, ExecutionSpec, ExecutionValidation, Machine, Result, Validation}

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
  @edges %{
    accepted: [:preparing, :cancelled, :expired],
    preparing: [:ready, :failed, :cancelled],
    ready: [:dispatching, :cancelled, :failed],
    dispatching: [:running, :collecting, :unknown, :cancelling],
    running: [:collecting, :unknown, :cancelling],
    cancelling: [:collecting, :unknown],
    unknown: [:collecting, :cancelling],
    collecting: [:completed, :collection_failed],
    completed: [],
    collection_failed: [],
    failed: [],
    cancelled: [],
    expired: []
  }
  @mutable [
    :state,
    :evidence,
    :result,
    :collection,
    :cleanup,
    :created_machine,
    :next_due_at_ms,
    :artifacts,
    :last_error,
    :cleanup_attempts,
    :absence_at_ms
  ]
  @evidence [
    :not_dispatched,
    :dispatch_uncertain,
    :running_observed,
    :exited,
    :termination_confirmed,
    :unknown
  ]

  @enforce_keys [
    :scope,
    :id,
    :fingerprint,
    :spec,
    :accepted_at_ms,
    :updated_at_ms,
    :next_due_at_ms,
    :deadlines
  ]
  @derive {Inspect, only: [:scope, :id, :version, :state, :evidence, :collection, :cleanup]}
  defstruct [
    :scope,
    :id,
    :fingerprint,
    :spec,
    :accepted_at_ms,
    :updated_at_ms,
    :next_due_at_ms,
    :worker_id,
    :worker_generation,
    :machine_name,
    :created_machine,
    :result,
    :last_error,
    :cancel_requested_at_ms,
    :claim_owner,
    :claim_until_ms,
    :absence_at_ms,
    schema: 1,
    version: 1,
    generation: 0,
    state: :accepted,
    evidence: :not_dispatched,
    collection: :pending,
    cleanup: :pending,
    cleanup_attempts: 0,
    reservation: nil,
    deadlines: %{},
    artifacts: [],
    errors: []
  ]

  @type key :: {String.t(), String.t()}
  @type state ::
          :accepted
          | :preparing
          | :ready
          | :dispatching
          | :running
          | :collecting
          | :completed
          | :collection_failed
          | :failed
          | :cancelled
          | :expired
          | :unknown
          | :cancelling
  @type t :: %__MODULE__{
          schema: 1,
          scope: String.t(),
          id: String.t(),
          fingerprint: String.t(),
          spec: ExecutionSpec.t(),
          accepted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          next_due_at_ms: non_neg_integer(),
          version: pos_integer(),
          generation: non_neg_integer(),
          state: state(),
          evidence: atom(),
          collection: :pending | :complete | :partial | :failed,
          cleanup: :pending | :in_progress | :complete | :failed,
          cleanup_attempts: non_neg_integer(),
          worker_id: String.t() | nil,
          worker_generation: non_neg_integer() | nil,
          machine_name: String.t() | nil,
          created_machine: Machine.t() | nil,
          result: Result.t() | nil,
          last_error: Error.t() | nil,
          cancel_requested_at_ms: non_neg_integer() | nil,
          claim_owner: String.t() | nil,
          claim_until_ms: non_neg_integer() | nil,
          absence_at_ms: non_neg_integer() | nil,
          reservation: %{atom() => pos_integer()} | nil,
          deadlines: %{atom() => non_neg_integer()},
          artifacts: [map()],
          errors: [%{at_ms: non_neg_integer(), error: Error.t()}]
        }

  @spec new(ExecutionSpec.t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(spec, fingerprint, now) do
    with :ok <- ExecutionSpec.validate(spec),
         true <- Validation.digest?(fingerprint) and timestamp?(now) do
      record = %__MODULE__{
        scope: spec.scope,
        id: spec.id,
        fingerprint: fingerprint,
        spec: spec,
        accepted_at_ms: now,
        updated_at_ms: now,
        next_due_at_ms: now,
        deadlines: %{queue: now + spec.queue_ms}
      }

      with :ok <- validate(record), do: {:ok, record}
    else
      _invalid -> invalid()
    end
  end

  @spec key(t()) :: key()
  def key(record), do: {record.scope, record.id}

  @doc "Validate a store patch; immutable identity, claims and reservations cannot be patched."
  @spec transition(t(), keyword(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def transition(record, changes, now) do
    with :ok <- validate(record),
         true <- Validation.keys?(changes, @mutable),
         true <- timestamp?(now) and now >= record.updated_at_ms,
         next = struct!(record, changes),
         true <- next.state == record.state or next.state in @edges[record.state],
         :ok <- evidence_transition(record, next),
         :ok <- validate(next) do
      next = %{next | version: record.version + 1, updated_at_ms: now}

      errors =
        if Keyword.has_key?(changes, :last_error) and next.last_error != nil,
          do: Enum.take([%{at_ms: now, error: next.last_error} | record.errors], 8),
          else: record.errors

      next = %{next | deadlines: stage_deadline(next, now), errors: errors}
      with :ok <- validate(next), do: {:ok, next}
    else
      _invalid -> invalid()
    end
  end

  @doc "Atomic store acceptance must call this before admission; queue expiry never dispatches."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(record, now), do: record.state == :accepted and now >= record.deadlines.queue

  @doc "States that require no further command dispatch or outcome observation."
  @spec terminal?(t()) :: boolean()
  def terminal?(record),
    do: record.state in [:completed, :collection_failed, :failed, :cancelled, :expired]

  @doc "Validate a persisted record after decoding it, including shapes that could contain BEAM resources."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = record) do
    with true <- Validation.struct_shape?(record, __MODULE__),
         :ok <- ExecutionSpec.validate(record.spec),
         true <- fields?(record),
         true <- ExecutionValidation.metadata?(record) do
      outcome(record)
    else
      _invalid -> invalid()
    end
  end

  def validate(_record), do: invalid()

  defp fields?(record) do
    checks = [
      record.schema == 1,
      record.state in @states,
      Validation.digest?(record.fingerprint),
      Validation.integer?(record.version, 1, 9_007_199_254_740_991),
      Validation.integer?(record.generation, 0, 9_007_199_254_740_991),
      timestamp?(record.accepted_at_ms),
      timestamp?(record.updated_at_ms),
      timestamp?(record.next_due_at_ms),
      optional_time?(record.cancel_requested_at_ms),
      optional_time?(record.claim_until_ms),
      optional_time?(record.absence_at_ms),
      is_nil(record.claim_owner) or Validation.identifier?(record.claim_owner),
      is_nil(record.worker_id) or Validation.identifier?(record.worker_id),
      is_nil(record.worker_generation) or
        Validation.integer?(record.worker_generation, 1, 9_007_199_254_740_991),
      is_nil(record.machine_name) or SmolBox.MachineSpec.valid_name?(record.machine_name),
      record.scope == record.spec.scope and record.id == record.spec.id,
      record.updated_at_ms >= record.accepted_at_ms
    ]

    Enum.all?(checks)
  end

  @doc false
  @spec timestamp?(term()) :: boolean()
  def timestamp?(value), do: Validation.integer?(value, 0, 253_402_300_000_000)

  defp outcome(record) do
    checks = [
      record.evidence in @evidence,
      record.collection in [:pending, :complete, :partial, :failed],
      record.cleanup in [:pending, :in_progress, :complete, :failed],
      Validation.integer?(record.cleanup_attempts, 0, 1000),
      result?(record.result, record.spec.profile.max_output_bytes),
      state_evidence?(record),
      collection_state?(record),
      record.cleanup != :complete or terminal?(record) or record.state == :unknown,
      record.cleanup != :complete or record.worker_id == nil or record.absence_at_ms != nil,
      timestamp?(record.next_due_at_ms)
    ]

    if Enum.all?(checks), do: :ok, else: invalid()
  end

  defp evidence_transition(previous, next) do
    valid =
      preserves?(previous, next, [:result, :created_machine, :absence_at_ms]) and
        (previous.evidence != :exited or next.evidence == :exited) and
        (previous.evidence != :termination_confirmed or
           next.evidence in [:termination_confirmed, :exited]) and
        (previous.cleanup != :complete or next.cleanup == :complete)

    if valid, do: :ok, else: invalid()
  end

  defp preserves?(previous, next, fields),
    do: Enum.all?(fields, &(Map.fetch!(previous, &1) in [nil, Map.fetch!(next, &1)]))

  defp state_evidence?(%{state: state} = record)
       when state in [:accepted, :preparing, :ready, :cancelled, :expired, :failed],
       do: record.evidence == :not_dispatched and record.result == nil

  defp state_evidence?(%{state: state} = record)
       when state in [:completed, :collecting, :collection_failed],
       do: record.evidence == :exited and record.result != nil

  defp state_evidence?(%{state: :dispatching} = record),
    do: record.evidence == :dispatch_uncertain and record.result == nil

  defp state_evidence?(%{state: :running} = record),
    do: record.evidence == :running_observed and record.result == nil

  defp state_evidence?(record),
    do:
      record.evidence in [
        :dispatch_uncertain,
        :running_observed,
        :unknown,
        :termination_confirmed
      ] and record.result == nil

  defp collection_state?(%{state: :completed, collection: status}), do: status == :complete

  defp collection_state?(%{state: :collection_failed, collection: status}),
    do: status in [:partial, :failed]

  defp collection_state?(_record), do: true

  defp stage_deadline(record, now) do
    budget =
      case record.state do
        :preparing -> {:preparation, record.spec.profile.preparation_ms}
        :dispatching -> {:execution, record.spec.profile.execution_ms}
        :collecting -> {:collection, record.spec.profile.collection_ms}
        _other -> nil
      end

    deadlines =
      if budget do
        {stage, ms} = budget
        Map.put_new(record.deadlines, stage, now + ms)
      else
        record.deadlines
      end

    if record.cleanup == :in_progress,
      do: Map.put_new(deadlines, :cleanup, cleanup_deadline(record, now)),
      else: deadlines
  end

  defp cleanup_deadline(record, now) do
    retention_until =
      if record.state == :unknown,
        do:
          Map.get(record.deadlines, :execution, record.accepted_at_ms) + record.spec.retention_ms,
        else: now

    max(now, retention_until) + record.spec.profile.cleanup_ms
  end

  defp result?(nil, _max), do: true

  defp result?(%Result{} = result, max) do
    Validation.struct_shape?(result, Result) and
      Validation.integer?(result.exit_code, -2_147_483_648, 2_147_483_647) and
      result.encoding in [:bytes, :lossy_utf8] and is_boolean(result.truncated) and
      is_binary(result.stdout) and
      is_binary(result.stderr) and
      byte_size(result.stdout) + byte_size(result.stderr) <= max
  end

  defp result?(_result, _max), do: false
  defp optional_time?(nil), do: true
  defp optional_time?(value), do: timestamp?(value)

  defp invalid, do: {:error, %Error{category: :validation, operation: :execution_state}}
end
