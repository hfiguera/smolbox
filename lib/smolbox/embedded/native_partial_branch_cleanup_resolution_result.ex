defmodule SmolBox.Embedded.NativePartialBranchCleanupResolutionResult do
  @moduledoc """
  Original terminal disposal made the accepted cleanup unnecessary. The distinct
  acknowledgement and fresh source observation close only its saved cleanup
  action. No residual removal or backing release is inferred.
  """
  alias SmolBox.Embedded.{
    NativePartialBranchCleanup,
    NativePartialBranchDisposalResult,
    PartialBranchDisposal,
    PartialBranchDisposalCleanupUnneeded
  }

  alias SmolBox.{Machine, Validation}
  @enforce_keys [:version, :source, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          source: Machine.t(),
          proof: PartialBranchDisposalCleanupUnneeded.t()
        }

  def bound?(
        %__MODULE__{proof: %PartialBranchDisposalCleanupUnneeded{} = proof} = result,
        parent,
        child
      ) do
    with true <- Validation.struct_shape?(result, __MODULE__),
         saved = child.branch.native_authority.partial_disposal.cleanup,
         true <-
           is_struct(saved, NativePartialBranchCleanup) and saved.proof == nil and
             saved.unneeded == nil,
         true <- NativePartialBranchCleanup.valid?(saved, child.branch.native_authority),
         true <- PartialBranchDisposalCleanupUnneeded.matches?(proof, saved.request),
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
