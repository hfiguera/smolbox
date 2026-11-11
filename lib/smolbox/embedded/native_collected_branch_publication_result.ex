defmodule SmolBox.Embedded.NativeCollectedBranchPublicationResult do
  @moduledoc """
  Material-only publication plus a separate fresh source observation for a
  paired transaction. This result grants no child readiness, activation,
  collection, deletion or resource release and carries no native owner handle.
  """
  alias SmolBox.Embedded.{BranchPublication, Identity, NativeCollectedBranchPublication}

  alias SmolBox.{DiskExpansion, Machine, Validation}
  @enforce_keys [:version, :platform, :proof, :source]
  @derive {Inspect, only: [:platform]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          platform: String.t(),
          proof: %BranchPublication{},
          source: Machine.t()
        }

  def bound?(
        %__MODULE__{
          proof: %BranchPublication{} = proof,
          source: %Machine{backend_identity: %Identity{} = identity}
        } = result,
        parent,
        child
      ) do
    Validation.struct_shape?(result, __MODULE__) and
      action?(result, child) and publication?(result, parent, child) and
      source?(result.source, identity, proof, parent, child)
  end

  def bound?(_, _, _), do: false

  defp action?(result, child) do
    saved = child.branch.native_authority.collected_publication

    is_struct(saved, NativeCollectedBranchPublication) and
      result.version == (saved.completion_version || child.version) and
      result.platform == saved.platform and result.proof.change["platform"] == saved.platform and
      BranchPublication.matches?(result.proof, saved.request["creation"])
  end

  defp publication?(result, parent, child) do
    saved = child.branch.native_authority.collected_publication

    (saved.proof == result.proof or
       (saved.proof == nil and
          not Map.has_key?(parent.native_branch_history, child.id))) and
      Identity.valid?(result.source.backend_identity) and
      result.source.backend_identity.receipt == result.proof.receipt and
      result.source.backend_identity.transition == result.proof
  end

  defp source?(source, identity, proof, parent, child) do
    expected = %{DiskExpansion.expected(parent) | backend_identity: identity}
    profile = DiskExpansion.profile(parent)
    pid = child.branch.source_machine.backend_identity.pid_identity

    Machine.same_incarnation?(expected, source) and
      get_in(proof.change, ~w(child_origin intent source_pid)) == pid and
      observed?(source.state, identity.pid_identity, pid) and
      {source.cpus, source.memory_mb, source.storage_gb, source.overlay_gb} ==
        {profile.cpus, profile.memory_mb, profile.storage_gb, profile.overlay_gb} and
      source.network == profile.network and source.ports == [] and source.mounts == []
  end

  defp observed?(:running, pid, pid), do: pid != nil
  defp observed?(:stopped, nil, _), do: true
  defp observed?(_, _, _), do: false
end
