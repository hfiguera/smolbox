defmodule SmolBox.Store.NativeBranchDeletionActionOps do
  @moduledoc false
  alias SmolBox.Embedded.{
    NativeBranchDeletionAction,
    NativeBranchDeletionCollection,
    NativeGrowth,
    NativeReleasedBranchDeletionCleanup,
    NativeReleasedBranchDeletionContinuation
  }

  alias SmolBox.{Error, ManagedMachine, Validation}
  alias SmolBox.Store.NativeBranchDeletionOps

  def accept(child, action, now) when action in [:collect, :continue, :cleanup] do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(child),
         true <- NativeBranchDeletionAction.eligible?(child, action) do
      case Map.fetch!(child.branch.native_authority, NativeBranchDeletionAction.field(action)) do
        %NativeBranchDeletionCollection{proof: nil} -> {:ok, child}
        %NativeBranchDeletionAction{proof: nil} -> {:ok, child}
        %NativeReleasedBranchDeletionContinuation{proof: nil} -> {:ok, child}
        %NativeReleasedBranchDeletionCleanup{proof: nil} -> {:ok, child}
        nil -> accept_new(child, action, now)
        _ -> error()
      end
    else
      _ -> error()
    end
  end

  def accept(_, _, _), do: error()

  defp accept_new(child, action, now) do
    with {:ok, receipt, _, _} <- NativeGrowth.head(child) do
      authority = child.branch.native_authority
      delete_version = elem(child.last_request, 1)

      module =
        cond do
          action == :collect ->
            NativeBranchDeletionCollection

          action == :continue and NativeReleasedBranchDeletionContinuation.eligible?(child) ->
            NativeReleasedBranchDeletionContinuation

          action == :cleanup and NativeReleasedBranchDeletionCleanup.eligible?(child) ->
            NativeReleasedBranchDeletionCleanup

          true ->
            NativeBranchDeletionAction
        end

      saved =
        struct!(module,
          version: child.version,
          delete_version: delete_version,
          request:
            module.intent(
              authority,
              action,
              child.version,
              delete_version,
              receipt
            )
        )

      authority = Map.put(authority, NativeBranchDeletionAction.field(action), saved)
      ManagedMachine.update(child, %{branch: %{child.branch | native_authority: authority}}, now)
    end
  end

  def complete(
        %ManagedMachine{branch: %{native_authority: %{delete_continuation: _, delete_cleanup: _}}} =
          child,
        action,
        proof,
        now
      )
      when action in [:collect, :continue, :cleanup] do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(child),
         authority = child.branch.native_authority,
         slot = NativeBranchDeletionAction.field(action),
         saved = Map.fetch!(authority, slot),
         true <- NativeBranchDeletionAction.matches?(saved, action, proof) do
      case saved.proof do
        ^proof -> {:ok, child}
        nil -> complete_new(child, authority, slot, saved, proof, action, now)
        _ -> error()
      end
    else
      _ -> error()
    end
  end

  def complete(_, _, _, _), do: error()

  defp complete_new(child, authority, slot, saved, proof, :collect, now) do
    if NativeBranchDeletionCollection.eligible?(child),
      do:
        ManagedMachine.update(
          child,
          %{
            branch: %{
              child.branch
              | native_authority: Map.put(authority, slot, %{saved | proof: proof})
            }
          },
          now
        ),
      else: error()
  end

  defp complete_new(child, authority, slot, saved, proof, action, now) do
    with true <- NativeBranchDeletionAction.eligible?(child, action),
         authority = Map.put(authority, slot, %{saved | proof: proof}),
         {:ok, child, nil} <- NativeBranchDeletionOps.finalize(child, authority, now),
         do: {:ok, child},
         else: (_ -> error())
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :reconcile}}
end
