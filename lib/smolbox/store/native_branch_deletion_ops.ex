defmodule SmolBox.Store.NativeBranchDeletionOps do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchDeletionResolution,
    NativeBranchDeletion,
    NativeGrowth,
    NativeReleasedBranchDeletion,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(child, now) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(child),
         true <- NativeBranchDeletion.resolvable?(child) do
      case child.branch.native_authority.deletion do
        %NativeBranchDeletion{} -> {:ok, child}
        %NativeReleasedBranchDeletion{} -> {:ok, child}
        nil -> accept_new(child, now)
      end
    else
      _ -> error()
    end
  end

  defp accept_new(child, now) do
    with {:ok, receipt, _, _} <- NativeGrowth.head(child) do
      authority = child.branch.native_authority

      module =
        if NativeReleasedBranchDeletion.eligible?(child),
          do: NativeReleasedBranchDeletion,
          else: NativeBranchDeletion

      saved =
        struct!(module,
          version: child.version,
          delete_version: elem(child.last_request, 1),
          request:
            module.intent(
              authority,
              child.version,
              elem(child.last_request, 1),
              receipt
            )
        )

      ManagedMachine.update(
        child,
        %{branch: %{child.branch | native_authority: %{authority | deletion: saved}}},
        now
      )
    end
  end

  def resolve(
        %ManagedMachine{branch: %{native_authority: %{deletion: saved}}} = child,
        proof,
        now
      )
      when is_struct(proof, BranchDeletionResolution) or
             is_struct(proof, ReleasedBranchDeletionResolution) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(child),
         true <- NativeBranchDeletion.matches?(saved, proof) do
      case saved.proof do
        ^proof -> {:ok, child, nil}
        nil -> complete(child, saved, proof, now)
        _ -> error()
      end
    else
      _ -> error()
    end
  end

  def resolve(_, _, _), do: error()

  defp complete(child, saved, proof, now) do
    authority = %{child.branch.native_authority | deletion: %{saved | proof: proof}}

    if NativeBranchDeletion.resolvable?(child),
      do: finalize(child, authority, now),
      else: error()
  end

  def finalize(child, authority, now) do
    case ManagedMachine.update(
           child,
           %{
             branch: %{child.branch | native_authority: authority},
             state: :deleted,
             reservation: nil,
             reserved_ports: [],
             operation: nil,
             phase: nil,
             active_execution: nil,
             operation_deadline_ms: nil,
             resolved_at_ms: now,
             absence_at_ms: child.absence_at_ms || now
           },
           now
         ) do
      {:ok, child} -> {:ok, child, nil}
      _ -> error()
    end
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :reconcile}}
end
