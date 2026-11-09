defmodule SmolBox.Store.CodecNativePartialBranchDisposals do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.CodecNativeCollectedBranchPublications
  @defaults %{NativeBranchAuthority => [partial_disposal: nil]}
  def reader, do: 1

  def transform(record, mode),
    do:
      CodecNativeCollectedBranchPublications.transform_predecessor(
        record,
        @defaults,
        mode,
        &required?/1
      )

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :partial_disposal) != nil

  def required?(_), do: false
end
