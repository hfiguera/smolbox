defmodule SmolBox.Branch do
  @moduledoc """
  Durable lineage and operation evidence carried by a managed child.

  A successful branch response binds the random recorded child name to the request
  on its recorded source. Upstream has no immutable ownership token or public
  lineage attestation. Namespace exclusivity remains required; an unknown child
  without a recorded creation response is never adopted by name.
  """
  alias SmolBox.{BranchSpec, Error, ManagedMachine, Validation}
  @enforce_keys [:source, :source_machine, :spec, :accepted_at_ms, :deadline_ms]
  defstruct @enforce_keys ++ [state: :accepted, release_version: nil, retired_at_ms: nil]

  @type state ::
          :accepted
          | :dispatching
          | :observed
          | :ready
          | :held
          | :release_pending
          | :release_dispatching
          | :released
          | :unknown
          | :resolved
          | :failed
          | :cancelled
          | :retired
          | :closed
  @type t :: %__MODULE__{
          source: ManagedMachine.key(),
          source_machine: SmolBox.Machine.t(),
          spec: BranchSpec.t(),
          accepted_at_ms: non_neg_integer(),
          deadline_ms: non_neg_integer(),
          state: state(),
          release_version: pos_integer() | nil,
          retired_at_ms: non_neg_integer() | nil
        }
  @states [
    :accepted,
    :dispatching,
    :observed,
    :ready,
    :held,
    :release_pending,
    :release_dispatching,
    :released,
    :unknown,
    :resolved,
    :failed,
    :cancelled,
    :retired,
    :closed
  ]
  @doc false
  def validate(%__MODULE__{} = b) do
    with true <- Validation.struct_shape?(b, __MODULE__),
         {scope, id} <- b.source,
         true <- Validation.identifier?(scope) and Validation.identifier?(id),
         :ok <- BranchSpec.validate(b.spec),
         true <- b.state in @states,
         true <- Validation.timestamp?(b.accepted_at_ms) and Validation.timestamp?(b.deadline_ms),
         true <- b.deadline_ms >= b.accepted_at_ms + b.spec.timeout_ms,
         true <-
           b.release_version == nil or
             Validation.integer?(b.release_version, 1, 9_007_199_254_740_991),
         true <- b.retired_at_ms == nil or Validation.timestamp?(b.retired_at_ms),
         true <- b.state in [:retired, :closed] == (b.retired_at_ms != nil),
         do: :ok,
         else: (_ -> invalid())
  end

  def validate(_), do: invalid()

  @doc false
  def valid_machine?(m) do
    is_map(m.branch_children) and map_size(m.branch_children) <= 256 and
      Enum.all?(m.branch_children, fn {id, retired} ->
        Validation.identifier?(id) and is_boolean(retired)
      end) and
      active?(m) and child?(m) and phase?(m)
  end

  defp active?(%{active_branch: nil, operation: op}), do: op != :branch

  defp active?(m),
    do:
      m.branch_children[m.active_branch] == false and m.operation == :branch and
        m.active_execution == nil

  defp child?(%{branch: nil}), do: true

  defp child?(m) do
    b = m.branch

    validate(b) == :ok and is_struct(b.source_machine, SmolBox.Machine) and b.spec.id == m.id and
      elem(b.source, 0) == m.scope and elem(b.source, 1) != m.id and
      child_spec?(m) and
      SmolBox.ExecutionValidation.machine?(b.source_machine, %{
        m
        | machine_name: b.source_machine.name
      })
  end

  defp child_spec?(m),
    do:
      m.spec.volumes == [] and m.branch_children == %{} and not m.spec.checkpointable and
        m.spec.workload == nil and m.spec.ports == [] and m.spec.profile.network == :offline

  defp phase?(%{branch: nil, operation: op}), do: op not in [:branch_child, :branch_release]

  defp phase?(%{branch: %{state: state}} = m) when state in [:accepted, :dispatching, :observed],
    do: m.operation == :branch_child and m.state == :creating and m.active_execution == nil

  defp phase?(%{branch: %{state: :unknown}} = m),
    do:
      m.operation in [:branch_child, :branch_release] and m.state == :unknown and
        m.active_execution == nil

  defp phase?(%{branch: %{state: state}} = m)
       when state in [:release_pending, :release_dispatching],
       do: m.operation == :branch_release and m.active_execution == nil

  defp phase?(%{branch: %{state: state}} = m)
       when state in [:failed, :cancelled, :resolved, :retired, :closed], do: m.state == :deleted

  defp phase?(%{branch: %{state: :held}, active_execution: execution}), do: execution == nil
  defp phase?(_), do: true

  @doc false
  def children_retired?(m), do: Enum.all?(m.branch_children, fn {_, retired} -> retired end)
  @doc false
  def usable?(%{branch: nil}), do: true
  def usable?(%{branch: %{state: state}}), do: state in [:ready, :released]
  @doc false
  def lifecycle?(m, action),
    do: children_retired?(m) and (usable?(m) or (action == :delete and m.branch.state == :held))

  @doc false
  def resources(%{branch: nil}), do: %{}
  def resources(%{branch: %{state: state}}) when state in [:failed, :cancelled, :closed], do: %{}
  def resources(%{branch: b}), do: b.spec.policy.resources
  defp invalid, do: {:error, %Error{category: :validation, operation: :branch}}
end
