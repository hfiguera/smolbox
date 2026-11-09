defmodule SmolBox.Store.CodecNativePartialBranchDisposals do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.CodecFields
  @defaults %{NativeBranchAuthority => [partial_disposal: nil]}
  def reader, do: 1

  def transform(record, mode),
    do: CodecFields.transform_optional(record, @defaults, mode, &required?/1)

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :partial_disposal) != nil

  def required?(_), do: false
end
