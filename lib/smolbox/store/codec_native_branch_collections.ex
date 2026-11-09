defmodule SmolBox.Store.CodecNativeBranchCollections do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.CodecFields
  @defaults %{NativeBranchAuthority => [delete_collection: nil]}

  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :delete_collection) != nil

  def required?(_), do: false
end
