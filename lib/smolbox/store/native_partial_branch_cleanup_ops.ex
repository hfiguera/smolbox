defmodule SmolBox.Store.NativePartialBranchCleanupOps do
  @moduledoc false
  alias SmolBox.Embedded.{NativeBranchAdmission, NativePartialBranchCleanup}
  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, platform, now) do
    with true <- Validation.timestamp?(now),
         true <- NativeBranchAdmission.partial_disposal_pending?(parent, child),
         disposal when not is_nil(disposal) <- child.branch.native_authority.partial_disposal,
         true <- disposal.proof == nil and disposal.platform == platform,
         saved = disposal.cleanup,
         true <- version == child.version or (saved != nil and version == saved.version) do
      if saved != nil,
        do: {:ok, parent, child},
        else: insert(parent, child, version, platform, now)
    else
      _ -> {:error, %Error{category: :identity_conflict, operation: :branch}}
    end
  end

  defp insert(parent, child, version, platform, now) do
    authority = child.branch.native_authority
    cleanup = NativePartialBranchCleanup.new(authority, version, platform)
    disposal = %{authority.partial_disposal | cleanup: cleanup}

    with {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :disposal_cleanup_pending,
                   native_authority: %{authority | partial_disposal: disposal}
               }
             },
             now
           ),
         {:ok, parent} <- ManagedMachine.update(parent, %{next_due_at_ms: now + 60_000}, now),
         do: {:ok, parent, child}
  end
end
