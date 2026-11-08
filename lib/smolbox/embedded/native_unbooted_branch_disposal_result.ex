defmodule SmolBox.Embedded.NativeUnbootedBranchDisposalResult do
  @moduledoc """
  Transient input for a paired original unbooted-child disposal transaction.
  The native proof is historical; a separate fresh source observation carries
  its actual publication. No child machine or boot completion is synthesized.
  """
  alias SmolBox.Embedded.{
    Identity,
    NativeGrowth,
    NativeUnbootedBranchDisposal,
    UnbootedBranchDisposal
  }

  alias SmolBox.{DiskExpansion, Machine, ManagedMachine, Validation}
  @enforce_keys [:version, :source, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          source: Machine.t(),
          proof: UnbootedBranchDisposal.t()
        }

  def bound?(
        %__MODULE__{
          source: %Machine{backend_identity: %Identity{} = identity},
          proof: %UnbootedBranchDisposal{} = proof
        } = result,
        parent,
        child
      ) do
    with true <- Validation.struct_shape?(result, __MODULE__) and result.version == child.version,
         saved = child.branch.native_authority.disposal,
         true <- is_struct(saved, NativeUnbootedBranchDisposal) and saved.proof == nil,
         true <- UnbootedBranchDisposal.matches?(proof, saved.request),
         true <- NativeUnbootedBranchDisposal.plan?(proof, child.spec.profile),
         {:ok, receipt, _, _} <- NativeGrowth.head(parent) do
      child.branch.source == ManagedMachine.key(parent) and
        receipt == proof.publication["previous"] and
        Identity.valid?(identity) and identity.receipt == proof.publication["receipt"] and
        source?(result.source, identity, parent, proof, child)
    else
      _ -> false
    end
  end

  def bound?(_, _, _), do: false

  defp source?(source, identity, parent, proof, child) do
    profile = DiskExpansion.profile(parent)
    pid = get_in(proof.publication, ~w(change child_origin intent source_pid))
    # bound?/3 already requires the exact previous/current publication heads.
    # Compare every other machine field against the authorized evolved identity.
    expected = %{DiskExpansion.expected(parent) | backend_identity: identity}

    pid == child.branch.source_machine.backend_identity.pid_identity and
      observed?(source.state, identity.pid_identity, pid) and
      Machine.same_incarnation?(expected, source) and
      {source.cpus, source.memory_mb, source.storage_gb, source.overlay_gb} ==
        {profile.cpus, profile.memory_mb, profile.storage_gb, profile.overlay_gb} and
      source.network == :offline and source.ports == [] and source.mounts == []
  end

  defp observed?(:running, pid, pid), do: pid != nil
  defp observed?(:stopped, nil, _), do: true
  defp observed?(_, _, _), do: false
end
