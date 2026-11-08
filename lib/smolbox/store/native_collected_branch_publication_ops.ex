defmodule SmolBox.Store.NativeCollectedBranchPublicationOps do
  @moduledoc false
  alias SmolBox.Embedded.{
    NativeCollectedBranchPublication,
    NativeCollectedBranchPublicationResult
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, platform, now) do
    with true <- Validation.timestamp?(now) and platform in ~w(linux macos),
         true <- NativeCollectedBranchPublication.pending?(parent, child),
         saved = child.branch.native_authority.collected_publication,
         true <- saved == nil or saved.platform == platform,
         collection = child.branch.native_authority.partial_collection,
         true <- collection == nil or collection.platform == platform,
         true <- version == child.version or (saved != nil and version == saved.version) do
      if saved != nil,
        do: {:ok, parent, child},
        else:
          save(
            parent,
            child,
            NativeCollectedBranchPublication.new(
              child.branch.native_authority,
              version,
              platform
            ),
            %{},
            now
          )
    else
      _ -> error()
    end
  end

  def complete(parent, child, %NativeCollectedBranchPublicationResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         true <- NativeCollectedBranchPublication.pending?(parent, child),
         true <- NativeCollectedBranchPublicationResult.bound?(result, parent, child) do
      saved = child.branch.native_authority.collected_publication

      cond do
        saved.proof == result.proof ->
          {:ok, parent, child}

        saved.proof == nil ->
          save(
            parent,
            child,
            %{saved | proof: result.proof, completion_version: child.version},
            %{
              native_branch_history:
                Map.put(parent.native_branch_history, child.id, result.proof),
              observed_machine: result.source
            },
            now
          )

        true ->
          error()
      end
    else
      _ -> error()
    end
  end

  def complete(_, _, _, _), do: error()

  defp save(parent, child, saved, changes, now) do
    with {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | native_authority: %{
                     child.branch.native_authority
                     | collected_publication: saved
                   }
               }
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(parent, Map.put(changes, :next_due_at_ms, now + 60_000), now),
         do: {:ok, parent, child}
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
