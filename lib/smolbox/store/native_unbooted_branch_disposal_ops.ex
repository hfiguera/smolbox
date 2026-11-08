defmodule SmolBox.Store.NativeUnbootedBranchDisposalOps do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAdmission

  alias SmolBox.Embedded.{
    BranchPublication,
    NativeUnbootedBranchDisposal,
    NativeUnbootedBranchDisposalResult
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, now) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- pending?(parent, child),
         saved = child.branch.native_authority.disposal,
         true <- version == child.version or (saved != nil and version == saved.version) do
      if saved != nil,
        do: {:ok, parent, child},
        else: insert(parent, child, version, now)
    else
      _ -> error()
    end
  end

  defp insert(parent, child, version, now) do
    saved = NativeUnbootedBranchDisposal.new(child.branch.native_authority, version)

    with {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :disposal_pending,
                   native_authority: %{child.branch.native_authority | disposal: saved}
               }
             },
             now
           ),
         {:ok, parent} <- ManagedMachine.update(parent, %{next_due_at_ms: now + 60_000}, now),
         do: {:ok, parent, child}
  end

  def pending?(parent, child), do: NativeBranchAdmission.disposal_pending?(parent, child)

  def resolve(parent, child, %NativeUnbootedBranchDisposalResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- pending?(parent, child),
         true <- NativeUnbootedBranchDisposalResult.bound?(result, parent, child),
         {:ok, publication} <- BranchPublication.from_wire(result.proof.publication),
         saved = %{
           child.branch.native_authority.disposal
           | proof: result.proof,
             completion_version: child.version
         },
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :disposed,
                   native_authority: %{child.branch.native_authority | disposal: saved}
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
               native_branch_history:
                 Map.put(parent.native_branch_history, child.id, publication),
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
