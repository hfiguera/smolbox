defmodule SmolBox.Embedded.NativePartialBranchDisposalResult do
  @moduledoc """
  Acknowledged original pre-handoff disposal and fresh source observation for
  an atomic source/child transaction. No child readiness or backing release is inferred.
  """
  alias SmolBox.Embedded.{
    Identity,
    NativeCollectedBranchPublication,
    NativePartialBranchDisposal,
    NativeUnbootedBranchDisposal,
    PartialBranchDisposal
  }

  alias SmolBox.{DiskExpansion, Machine, ManagedMachine, Validation}
  @enforce_keys [:version, :source, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          source: Machine.t(),
          proof: PartialBranchDisposal.t()
        }

  def bound?(
        result,
        parent,
        %{branch: %{native_authority: %{partial_disposal: %{cleanup: nil}}}} = child
      ),
      do: context_bound?(result, parent, child)

  def bound?(_, _, _), do: false

  @doc false
  def context_bound?(
        %__MODULE__{
          source: %Machine{backend_identity: %Identity{} = identity},
          proof: %PartialBranchDisposal{} = proof
        } = result,
        parent,
        child
      ) do
    with true <- Validation.struct_shape?(result, __MODULE__) and result.version == child.version,
         saved = child.branch.native_authority.partial_disposal,
         true <- is_struct(saved, NativePartialBranchDisposal) and saved.proof == nil,
         true <- NativePartialBranchDisposal.valid?(saved, child.branch.native_authority),
         true <- PartialBranchDisposal.matches?(proof, saved.request),
         true <- proof.publication["change"]["platform"] == saved.platform do
      child.branch.source == ManagedMachine.key(parent) and
        NativeCollectedBranchPublication.publication_pending?(parent, child, proof.publication) and
        Identity.valid?(identity) and identity.receipt == proof.publication["receipt"] and
        source?(result.source, identity, parent, proof, child)
    else
      _ -> false
    end
  end

  def context_bound?(_, _, _), do: false

  defp source?(source, identity, parent, proof, child) do
    profile = DiskExpansion.profile(parent)
    pid = get_in(proof.publication, ~w(change child_origin intent source_pid))
    expected = %{DiskExpansion.expected(parent) | backend_identity: identity}

    pid == child.branch.source_machine.backend_identity.pid_identity and
      observed?(source.state, identity.pid_identity, pid) and
      Machine.same_incarnation?(expected, source) and
      {source.cpus, source.memory_mb, source.storage_gb, source.overlay_gb} ==
        {profile.cpus, profile.memory_mb, profile.storage_gb, profile.overlay_gb} and
      source.network == :offline and source.ports == [] and source.mounts == [] and
      NativeUnbootedBranchDisposal.plan?(proof, child.spec.profile)
  end

  defp observed?(:running, pid, pid), do: pid != nil
  defp observed?(:stopped, nil, _), do: true
  defp observed?(_, _, _), do: false
end
