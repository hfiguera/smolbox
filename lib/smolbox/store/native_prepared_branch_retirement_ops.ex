defmodule SmolBox.Store.NativePreparedBranchRetirementOps do
  @moduledoc false
  alias SmolBox.Embedded.{NativePreparedBranchRetirement, NativePreparedBranchRetirementResult}
  alias SmolBox.{Error, ManagedMachine, Validation}

  def resolve(
        parent,
        %{branch: %{native_authority: authority}} = child,
        %NativePreparedBranchRetirementResult{} = result,
        now
      )
      when not is_nil(authority) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- parent.active_branch == child.id and parent.operation == :branch,
         true <- child.branch.state == :unknown and child.operation == :branch_child,
         true <- parent.branch_children[child.id] == false,
         true <- not Map.has_key?(parent.native_branch_history, child.id),
         true <-
           parent.worker_id == child.worker_id and
             parent.worker_generation == child.worker_generation,
         true <- NativePreparedBranchRetirementResult.bound?(result, parent, child),
         saved = %NativePreparedBranchRetirement{
           version: child.version,
           request: NativePreparedBranchRetirement.request(child.branch.native_authority),
           proof: result.proof
         },
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :closed,
                   retired_at_ms: now,
                   native_authority: %{child.branch.native_authority | prepared_retirement: saved}
               },
               state: :deleted,
               reservation: nil,
               reserved_ports: [],
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               last_error: nil,
               absence_at_ms: child.absence_at_ms || now
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               native_branch_history: Map.put(parent.native_branch_history, child.id, saved),
               branch_children: Map.put(parent.branch_children, child.id, true),
               active_branch: nil,
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               state: result.source.state,
               observed_machine: result.source,
               last_error: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  def resolve(_, _, _, _), do: error()
  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
