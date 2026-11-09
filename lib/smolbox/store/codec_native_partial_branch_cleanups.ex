defmodule SmolBox.Store.CodecNativePartialBranchCleanups do
  @moduledoc false
  alias SmolBox.Embedded.NativePartialBranchDisposal
  alias SmolBox.Store.CodecNativeCollectedBranchPublications
  @defaults %{NativePartialBranchDisposal => [cleanup: nil]}
  def reader, do: 1

  def transform(record, mode),
    do:
      CodecNativeCollectedBranchPublications.transform_predecessor(
        record,
        @defaults,
        mode,
        &required?/1
      )

  def required?(%{branch: %{native_authority: %{partial_disposal: disposal}}})
      when is_map(disposal),
      do: Map.get(disposal, :cleanup) != nil

  def required?(_), do: false
end
