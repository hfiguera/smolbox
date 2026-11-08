defmodule SmolBox.Store.NativeBranchRetirementOps do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchChildAbsence,
    NativeBranchRetirement,
    PartialBranchChildAbsence,
    UnbootedBranchChildAbsence
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def retire(parent, child, proof, now)
      when is_struct(proof, BranchChildAbsence) or is_struct(proof, UnbootedBranchChildAbsence) or
             is_struct(proof, PartialBranchChildAbsence) do
    with true <- Validation.timestamp?(now) and NativeBranchRetirement.pair?(parent, child),
         {:ok, request} <- NativeBranchRetirement.request(child),
         true <- NativeBranchRetirement.matches?(proof, request) do
      commit(parent, child, proof, now)
    else
      _ -> error()
    end
  end

  def retire(_, _, _, _), do: error()

  defp commit(
         parent,
         %{branch: %{state: state, native_authority: %{retirement: %NativeBranchRetirement{}}}} =
           child,
         _proof,
         _now
       )
       when state in [:retired, :backing_pending, :closed],
       do: if(parent.branch_children[child.id] == true, do: {:ok, parent, child}, else: error())

  defp commit(_, %{branch: %{state: :closed}}, _, _), do: error()

  defp commit(parent, child, proof, now) do
    authority = %{
      child.branch.native_authority
      | retirement: %NativeBranchRetirement{version: child.version, proof: proof}
    }

    with true <- parent.branch_children[child.id] == (child.branch.state == :retired),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :retired,
                   retired_at_ms: child.branch.retired_at_ms || now,
                   native_authority: authority
               }
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{branch_children: Map.put(parent.branch_children, child.id, true)},
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
