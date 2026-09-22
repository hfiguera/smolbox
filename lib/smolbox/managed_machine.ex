defmodule SmolBox.ManagedMachine do
  @moduledoc """
  Durable ownership and lifecycle of a retained machine, independent of commands.

  `created_machine` is immutable creation evidence; `observed_machine` is the last
  verified observation. A missing or unreachable worker never authorizes a fresh
  machine under this identity. Reservations remain charged until verified deletion.
  `active_execution` excludes other commands and lifecycle requests. Uncertain
  mutations require explicit operator resolution before the machine can be reused.
  """
  alias SmolBox.{Error, Machine, ManagedMachineSpec, Validation}
  alias SmolBox.Store.RecordOps

  @enforce_keys [
    :scope,
    :id,
    :spec,
    :fingerprint,
    :accepted_at_ms,
    :updated_at_ms,
    :next_due_at_ms
  ]
  @derive {Inspect, only: [:scope, :id, :version, :state, :operation, :phase, :active_execution]}
  defstruct @enforce_keys ++
              [
                :worker_id,
                :worker_generation,
                :machine_name,
                :created_machine,
                :observed_machine,
                :reservation,
                :active_execution,
                :claim_owner,
                :claim_until_ms,
                :absence_at_ms,
                :last_error,
                :last_request,
                :operation_deadline_ms,
                :resolved_at_ms,
                reserved_ports: [],
                schema: 1,
                version: 1,
                generation: 0,
                state: :accepted,
                operation: :create,
                phase: :pending
              ]

  @type t :: %__MODULE__{}
  @type key :: {String.t(), String.t()}
  @states [
    :accepted,
    :creating,
    :created,
    :running,
    :stopped,
    :starting,
    :stopping,
    :deleting,
    :unknown,
    :missing,
    :conflict,
    :deleted
  ]
  @mutable [
    :state,
    :operation,
    :phase,
    :created_machine,
    :observed_machine,
    :next_due_at_ms,
    :last_error,
    :operation_deadline_ms,
    :absence_at_ms
  ]

  @spec new(ManagedMachineSpec.t(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(%ManagedMachineSpec{} = spec, fingerprint, now) do
    record = %__MODULE__{
      scope: spec.scope,
      id: spec.id,
      spec: spec,
      fingerprint: fingerprint,
      accepted_at_ms: now,
      updated_at_ms: now,
      next_due_at_ms: now
    }

    with :ok <- validate(record), do: {:ok, record}
  end

  def new(_spec, _fingerprint, _now), do: invalid()

  @spec key(t()) :: key()
  def key(record), do: {record.scope, record.id}

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = record) do
    with true <- Validation.struct_shape?(record, __MODULE__),
         :ok <- ManagedMachineSpec.validate(record.spec),
         true <- fields?(record) and ownership?(record) and lifecycle?(record) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_record), do: invalid()

  @doc false
  def transition(record, changes, now) do
    with :ok <- validate(record),
         true <- Validation.keys?(changes, @mutable),
         true <-
           is_nil(record.created_machine) or
             Keyword.get(changes, :created_machine, record.created_machine) ==
               record.created_machine,
         true <-
           is_nil(record.absence_at_ms) or
             Keyword.get(changes, :absence_at_ms, record.absence_at_ms) == record.absence_at_ms,
         true <- record.state != :deleted or Keyword.get(changes, :state, :deleted) == :deleted do
      patch = Map.new(changes)
      patch = if patch[:state] == :deleted, do: Map.put(patch, :reservation, nil), else: patch
      patch = if patch[:state] == :deleted, do: Map.put(patch, :reserved_ports, []), else: patch
      update(record, patch, now)
    else
      _invalid -> invalid()
    end
  end

  @doc false
  def update(record, changes, now) do
    with true <- Validation.timestamp?(now),
         now = max(now, record.updated_at_ms),
         next =
           struct!(record, Map.merge(changes, %{version: record.version + 1, updated_at_ms: now})),
         :ok <- validate(next) do
      {:ok, next}
    else
      _invalid -> invalid()
    end
  end

  @doc false
  def idle?(record),
    do: record.active_execution == nil and record.operation == nil and record.phase == nil

  @doc false
  def due?(record, now),
    do:
      record.state != :deleted and record.active_execution == nil and record.next_due_at_ms <= now

  defp fields?(r) do
    Enum.all?([
      r.scope == r.spec.scope and r.id == r.spec.id,
      r.schema == 1,
      Validation.digest?(r.fingerprint),
      r.state in @states,
      Validation.integer?(r.version, 1, 9_007_199_254_740_991),
      Validation.integer?(r.generation, 0, 9_007_199_254_740_991),
      timestamps?(r),
      r.claim_owner == nil or Validation.identifier?(r.claim_owner),
      active?(r.active_execution, r.scope),
      request?(r.last_request),
      SmolBox.ExecutionValidation.error?(r.last_error)
    ])
  end

  defp timestamps?(r) do
    Enum.all?([r.accepted_at_ms, r.updated_at_ms, r.next_due_at_ms], &Validation.timestamp?/1) and
      r.updated_at_ms >= r.accepted_at_ms and
      Enum.all?(
        [r.claim_until_ms, r.absence_at_ms, r.operation_deadline_ms, r.resolved_at_ms],
        &(is_nil(&1) or Validation.timestamp?(&1))
      )
  end

  defp ownership?(%{worker_id: nil} = r),
    do:
      r.machine_name == nil and r.worker_generation == nil and r.reservation == nil and
        r.reserved_ports == [] and
        r.created_machine == nil and r.observed_machine == nil and
        (r.state in [:accepted, :deleted] or
           (r.state == :conflict and match?(%Error{category: :port_conflict}, r.last_error)))

  defp ownership?(r) do
    Enum.all?([
      Validation.identifier?(r.worker_id),
      SmolBox.MachineSpec.valid_name?(r.machine_name),
      Validation.integer?(r.worker_generation, 1, 9_007_199_254_740_991),
      r.reservation == RecordOps.resources(r) or (r.state == :deleted and r.reservation == nil),
      r.reserved_ports == if(r.state == :deleted, do: [], else: Enum.map(r.spec.ports, & &1.host)),
      observation?(r.created_machine, r),
      observation?(r.observed_machine, r),
      same_observation?(r)
    ])
  end

  defp same_observation?(%{created_machine: nil}), do: true
  defp same_observation?(%{observed_machine: nil}), do: true

  defp same_observation?(%{
         created_machine: %Machine{} = created,
         observed_machine: %Machine{} = observed
       }),
       do: Machine.same_incarnation?(created, observed)

  defp same_observation?(_record), do: false

  defp observation?(machine, record), do: SmolBox.ExecutionValidation.machine?(machine, record)

  defp lifecycle?(r) do
    Enum.all?([
      r.operation in [nil, :create, :start, :stop, :delete],
      r.phase in [nil, :pending, :dispatching, :uncertain],
      r.operation == nil == (r.phase == nil),
      r.state not in [:created, :running, :stopped] or r.created_machine != nil,
      r.active_execution == nil or (r.operation == nil and r.state in [:running, :unknown]),
      deletion?(r)
    ])
  end

  defp deletion?(%{state: :deleted} = r),
    do:
      r.active_execution == nil and r.operation == nil and
        (r.worker_id == nil or r.absence_at_ms != nil)

  defp deletion?(_r), do: true

  defp active?(nil, _scope), do: true
  defp active?({scope, id}, scope), do: Validation.identifier?(id)
  defp active?(_key, _scope), do: false
  defp request?(nil), do: true

  defp request?({operation, version}),
    do:
      operation in [:start, :stop, :delete] and
        Validation.integer?(version, 1, 9_007_199_254_740_991)

  defp request?(_request), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :machine}}
end
