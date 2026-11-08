defmodule SmolBox.Embedded.NativePartialBranchCleanupResult do
  @moduledoc """
  Original partial-disposal cleanup acknowledgement paired with a fresh source
  observation. Only its saved cleanup request may commit this disposal path.
  """
  alias SmolBox.Embedded.{
    NativePartialBranchCleanup,
    NativePartialBranchDisposalResult,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup
  }

  alias SmolBox.{Machine, Validation}
  @enforce_keys [:version, :source, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          source: Machine.t(),
          proof: PartialBranchDisposalCleanup.t()
        }

  def bound?(%__MODULE__{proof: %PartialBranchDisposalCleanup{} = proof} = result, parent, child) do
    with true <- Validation.struct_shape?(result, __MODULE__),
         saved = child.branch.native_authority.partial_disposal.cleanup,
         true <-
           is_struct(saved, NativePartialBranchCleanup) and saved.proof == nil and
             saved.unneeded == nil,
         true <- NativePartialBranchCleanup.valid?(saved, child.branch.native_authority),
         true <- PartialBranchDisposalCleanup.matches?(proof, saved.request),
         {:ok, disposal} <- PartialBranchDisposal.from_wire(proof.disposal) do
      NativePartialBranchDisposalResult.context_bound?(
        %NativePartialBranchDisposalResult{
          version: result.version,
          source: result.source,
          proof: disposal
        },
        parent,
        child
      )
    else
      _ -> false
    end
  end

  def bound?(_, _, _), do: false
end
