defmodule SmolBox.Store.NativePartialBranchDisposalOps do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchPublication,
    NativePartialBranchCleanupResolutionResult,
    NativePartialBranchCleanupResult,
    NativePartialBranchDisposal,
    NativePartialBranchDisposalResult,
    PartialBranchDisposal
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, platform, now) do
    with true <- Validation.timestamp?(now) and platform in ~w(linux macos),
         true <- NativePartialBranchDisposal.pending?(parent, child),
         saved = child.branch.native_authority.partial_disposal,
         true <- platform == child.branch.native_authority.partial_collection.platform,
         true <- version == child.version or (saved != nil and version == saved.version) do
      if saved != nil,
        do: {:ok, parent, child},
        else: insert(parent, child, version, platform, now)
    else
      _ -> error()
    end
  end

  defp insert(parent, child, version, platform, now) do
    saved = NativePartialBranchDisposal.new(child.branch.native_authority, version, platform)

    with {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :disposal_pending,
                   native_authority: %{child.branch.native_authority | partial_disposal: saved}
               }
             },
             now
           ),
         {:ok, parent} <- ManagedMachine.update(parent, %{next_due_at_ms: now + 60_000}, now),
         do: {:ok, parent, child}
  end

  def resolve(parent, child, %NativePartialBranchDisposalResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         true <- NativePartialBranchDisposal.pending?(parent, child),
         true <- NativePartialBranchDisposalResult.bound?(result, parent, child) do
      saved = %{
        child.branch.native_authority.partial_disposal
        | proof: result.proof,
          completion_version: child.version
      }

      complete(parent, child, result.source, saved, now)
    else
      _ -> error()
    end
  end

  def resolve(parent, child, %NativePartialBranchCleanupResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         true <- NativePartialBranchDisposal.pending?(parent, child),
         true <- NativePartialBranchCleanupResult.bound?(result, parent, child),
         {:ok, proof} <- PartialBranchDisposal.from_wire(result.proof.disposal) do
      disposal = child.branch.native_authority.partial_disposal
      cleanup = %{disposal.cleanup | proof: result.proof, completion_version: child.version}
      saved = %{disposal | proof: proof, completion_version: child.version, cleanup: cleanup}
      complete(parent, child, result.source, saved, now)
    else
      _ -> error()
    end
  end

  def resolve(parent, child, %NativePartialBranchCleanupResolutionResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         true <- NativePartialBranchDisposal.pending?(parent, child),
         true <- NativePartialBranchCleanupResolutionResult.bound?(result, parent, child),
         {:ok, proof} <- PartialBranchDisposal.from_wire(result.proof.disposal) do
      disposal = child.branch.native_authority.partial_disposal
      cleanup = %{disposal.cleanup | unneeded: result.proof, completion_version: child.version}
      saved = %{disposal | proof: proof, completion_version: child.version, cleanup: cleanup}
      complete(parent, child, result.source, saved, now)
    else
      _ -> error()
    end
  end

  def resolve(_, _, _, _), do: error()

  defp complete(parent, child, source, saved, now) do
    with {:ok, publication} <- BranchPublication.from_wire(saved.proof.publication),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :disposed,
                   native_authority: %{child.branch.native_authority | partial_disposal: saved}
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
               state: source.state,
               observed_machine: source,
               last_error: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
