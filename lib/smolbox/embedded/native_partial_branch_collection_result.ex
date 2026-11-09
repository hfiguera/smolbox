defmodule SmolBox.Embedded.NativePartialBranchCollectionResult do
  @moduledoc """
  Transient original-child collection result for a paired source/child transaction.

  The typed proof binds the accepted creation/action request, pinned platform and
  current child version. Recording it preserves unknown creation and every
  reservation, dependency, disk and backing charge. It grants no deletion,
  absence, initialized readiness or source material transition.
  """
  alias SmolBox.Embedded.{NativePartialBranchCollection, PartialBranchCollection}
  alias SmolBox.Validation
  @enforce_keys [:version, :proof, :platform]
  @derive {Inspect, only: [:platform]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          proof: PartialBranchCollection.t(),
          platform: String.t()
        }

  def valid?(%__MODULE__{} = result),
    do:
      Validation.struct_shape?(result, __MODULE__) and
        Validation.integer?(result.version, 1, 9_007_199_254_740_991) and
        is_struct(result.proof, PartialBranchCollection) and
        PartialBranchCollection.valid?(result.proof) and result.platform in ~w(linux macos)

  def valid?(_), do: false

  def bound?(
        %__MODULE__{} = result,
        %{
          branch: %{
            native_authority: %{partial_collection: %NativePartialBranchCollection{} = saved}
          }
        } = child
      ),
      do:
        valid?(result) and result.version == (saved.completion_version || child.version) and
          result.platform == saved.platform and
          PartialBranchCollection.matches?(result.proof, saved.request)

  def bound?(_, _), do: false
end
