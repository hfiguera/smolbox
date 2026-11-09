defmodule SmolBox.Embedded.NativePreparedBranchRetirementResult do
  @moduledoc """
  Prepared-only retirement paired with a fresh, unchanged source observation.

  This transient input is consumed by an atomic source/child store transaction.
  It is never child absence, a material transition, or entered backing disposal.
  """
  alias SmolBox.Embedded.{
    Identity,
    NativeGrowth,
    NativePreparedBranchRetirement,
    PreparedBranchRetirement
  }

  alias SmolBox.{Machine, ManagedMachine, Validation}

  @enforce_keys [:version, :source, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          source: Machine.t(),
          proof: PreparedBranchRetirement.t()
        }

  def bound?(
        %__MODULE__{source: %Machine{backend_identity: %Identity{} = identity}} = result,
        parent,
        child
      ) do
    with true <- Validation.struct_shape?(result, __MODULE__) and result.version == child.version,
         authority when not is_nil(authority) <- child.branch.native_authority,
         saved = %NativePreparedBranchRetirement{
           version: result.version,
           request: NativePreparedBranchRetirement.request(authority),
           proof: result.proof
         },
         true <- NativePreparedBranchRetirement.valid?(saved, authority),
         true <- NativePreparedBranchRetirement.plan?(saved, child.spec.profile),
         {:ok, receipt, _, _} <- NativeGrowth.head(parent) do
      authority.source == ManagedMachine.key(parent) and
        receipt == authority.request["source"] and identity.receipt == receipt and
        source?(result.source, identity, parent, child.spec.profile) and
        result.proof.retirement["intent"]["source_pid"] ==
          child.branch.source_machine.backend_identity.pid_identity
    else
      _ -> false
    end
  end

  def bound?(_, _, _), do: false

  defp source?(source, identity, parent, profile),
    do:
      Identity.valid?(identity) and observed_state?(source.state, identity.pid_identity) and
        Machine.same_incarnation?(SmolBox.DiskExpansion.expected(parent), source) and
        {source.cpus, source.memory_mb, source.storage_gb, source.overlay_gb} ==
          {profile.cpus, profile.memory_mb, profile.storage_gb, profile.overlay_gb} and
        source.network == :offline and source.ports == [] and source.mounts == []

  defp observed_state?(:running, pid), do: pid != nil
  defp observed_state?(:stopped, pid), do: pid == nil
  defp observed_state?(_, _), do: false
end
