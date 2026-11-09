defmodule SmolBox.Store.NativePartialBranchCollectionOps do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAdmission
  alias SmolBox.Embedded.{NativePartialBranchCollection, NativePartialBranchCollectionResult}
  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, platform, now) do
    with true <- Validation.timestamp?(now) and platform in ~w(macos linux),
         true <- NativeBranchAdmission.partial_collection_pending?(parent, child),
         saved = child.branch.native_authority.partial_collection,
         true <- saved == nil or saved.platform == platform,
         true <- version == child.version or (saved != nil and version == saved.version) do
      if saved != nil,
        do: {:ok, parent, child},
        else:
          save(
            parent,
            child,
            NativePartialBranchCollection.new(
              child.branch.native_authority,
              version,
              platform
            ),
            now
          )
    else
      _ -> error()
    end
  end

  def complete(parent, child, %NativePartialBranchCollectionResult{} = result, now) do
    with true <- Validation.timestamp?(now),
         true <- NativeBranchAdmission.partial_collection_pending?(parent, child),
         true <- NativePartialBranchCollectionResult.bound?(result, child) do
      saved = child.branch.native_authority.partial_collection

      cond do
        saved.proof == result.proof ->
          {:ok, parent, child}

        saved.proof == nil ->
          save(
            parent,
            child,
            %{saved | proof: result.proof, completion_version: child.version},
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

  defp save(parent, child, saved, now) do
    with {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | native_authority: %{child.branch.native_authority | partial_collection: saved}
               }
             },
             now
           ),
         {:ok, parent} <- ManagedMachine.update(parent, %{next_due_at_ms: now + 60_000}, now),
         do: {:ok, parent, child}
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
