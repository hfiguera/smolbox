defmodule SmolBox.Embedded.NativePartialBranchCleanupCandidate do
  @moduledoc false
  alias SmolBox.Embedded.{
    NativeCollectedBranchPublication,
    NativePartialBranchDisposal,
    NativeUnbootedBranchDisposal,
    PartialBranchCleanupCandidate
  }

  alias SmolBox.{ManagedMachine, Validation}
  @enforce_keys [:version, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  # Transient eligibility, never a durable action or completion acknowledgement.
  def bound?(%__MODULE__{proof: %PartialBranchCleanupCandidate{} = proof} = result, parent, child) do
    with true <- Validation.struct_shape?(result, __MODULE__) and result.version == child.version,
         true <- NativePartialBranchDisposal.pending?(parent, child),
         %{proof: nil, cleanup: nil} = saved <- child.branch.native_authority.partial_disposal,
         true <- PartialBranchCleanupCandidate.matches?(proof, saved.request) do
      NativeCollectedBranchPublication.publication_pending?(parent, child, proof.publication) and
        proof.publication["change"]["platform"] == saved.platform and
        child.branch.source == ManagedMachine.key(parent) and
        get_in(proof.publication, ~w(change child_origin intent source_pid)) ==
          child.branch.source_machine.backend_identity.pid_identity and
        NativeUnbootedBranchDisposal.plan?(proof, child.spec.profile)
    else
      _ -> false
    end
  end

  def bound?(_, _, _), do: false
end
