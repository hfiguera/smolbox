defmodule SmolBox.Export do
  @moduledoc """
  Durable export record, separate from command executions.

  An export handle is `{scope, machine_id, export_id}`. Records are retained in
  their managed machine's history, including after deletion. `:accepted` may be
  cancelled safely; `:dispatching` and `:unknown` can conceal continuing worker
  activity. `:verifying` has a worker receipt but is not a verified publication.
  `:resolved_unknown` records an operator's quiescence decision without claiming
  that publication failed. `:published` and `:completed` have a verified reusable result.
  """
  alias SmolBox.{Error, ExportReceipt, ExportResult, ExportSpec, Validation}
  @enforce_keys [:machine, :spec, :fingerprint, :accepted_at_ms, :updated_at_ms, :deadline_ms]
  @derive {Inspect, only: [:machine, :state, :version]}
  defstruct @enforce_keys ++
              [
                state: :accepted,
                version: 1,
                receipt: nil,
                result: nil,
                error: nil,
                resolved_at_ms: nil
              ]

  @type state ::
          :accepted
          | :dispatching
          | :verifying
          | :published
          | :unknown
          | :completed
          | :failed
          | :cancelled
          | :resolved_unknown
  @type t :: %__MODULE__{
          machine: SmolBox.ManagedMachine.key(),
          spec: ExportSpec.t(),
          fingerprint: String.t(),
          accepted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          deadline_ms: non_neg_integer(),
          state: state(),
          version: pos_integer(),
          receipt: ExportReceipt.t() | nil,
          result: ExportResult.t() | nil,
          error: Error.t() | nil,
          resolved_at_ms: non_neg_integer() | nil
        }
  @type handle :: {String.t(), String.t(), String.t()}
  @terminal [:completed, :failed, :cancelled, :resolved_unknown]

  @doc false
  def new(machine, spec, fingerprint, now) do
    record = %__MODULE__{
      machine: machine,
      spec: spec,
      fingerprint: fingerprint,
      accepted_at_ms: now,
      updated_at_ms: now,
      deadline_ms: now + spec.timeout_ms
    }

    with :ok <- validate(record), do: {:ok, record}
  end

  @doc false
  def validate(%__MODULE__{} = record) do
    with true <- Validation.struct_shape?(record, __MODULE__),
         :ok <- ExportSpec.validate(record.spec),
         true <- key?(record.machine) and Validation.digest?(record.fingerprint),
         true <- Validation.integer?(record.version, 1, 9_007_199_254_740_991),
         true <-
           Enum.all?(
             [record.accepted_at_ms, record.updated_at_ms, record.deadline_ms],
             &Validation.timestamp?/1
           ),
         true <- record.updated_at_ms >= record.accepted_at_ms,
         true <- record.deadline_ms == record.accepted_at_ms + record.spec.timeout_ms,
         true <-
           record.state in (@terminal ++
                              [:accepted, :dispatching, :verifying, :published, :unknown]),
         true <- record.receipt == nil or ExportReceipt.validate(record.receipt) == :ok,
         true <- result?(record),
         true <- SmolBox.ExecutionValidation.error?(record.error),
         true <- record.resolved_at_ms == nil or Validation.timestamp?(record.resolved_at_ms),
         true <-
           record.state not in [:resolved_unknown, :completed] or record.resolved_at_ms != nil,
         true <-
           record.state not in [:accepted, :dispatching, :failed, :cancelled] or
             record.receipt == nil,
         true <- record.state != :verifying or record.receipt != nil do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_record), do: invalid()

  @doc false
  def terminal?(record), do: record.state in @terminal

  @doc false
  def history_valid?(machine) do
    is_map(machine.exports) and map_size(machine.exports) <= 256 and
      Enum.all?(machine.exports, fn {id, record} ->
        validate(record) == :ok and record.spec.id == id and
          record.machine == {machine.scope, machine.id} and
          (terminal?(record) or machine.active_export == id)
      end) and active?(machine)
  end

  @doc false
  def resources(machine) do
    if machine.active_export,
      do: machine.exports[machine.active_export].spec.destination.resources,
      else: %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}
  end

  defp active?(%{active_export: nil, operation: operation}), do: operation != :export

  defp active?(machine) do
    case machine.exports[machine.active_export] do
      %__MODULE__{} = record ->
        not terminal?(record) and machine.operation == :export and
          machine.active_execution == nil and
          machine.state in [:stopped, :unknown, :missing, :conflict]

      _invalid ->
        false
    end
  end

  defp result?(
         %{
           state: state,
           receipt: %ExportReceipt{} = receipt,
           result: %ExportResult{} = result
         } = record
       )
       when state in [:completed, :published] do
    ExportResult.validate(result) == :ok and result.manifest_sha256 == receipt.manifest_sha256 and
      result.size_bytes == receipt.size_bytes and result.platform == receipt.platform and
      result.reference ==
        SmolBox.ExportDestination.reference(
          record.spec.destination,
          "sha256:" <> receipt.manifest_sha256
        )
  end

  defp result?(%{state: state, result: nil}), do: state not in [:completed, :published]
  defp result?(_record), do: false
  defp key?({scope, id}), do: Validation.identifier?(scope) and Validation.identifier?(id)
  defp key?(_key), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :export}}
end
