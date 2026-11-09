defmodule SmolBox.Store.CodecNativeBranchCollections do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativePartialBranchCollections}
  @defaults %{NativeBranchAuthority => [delete_collection: nil]}

  def strip(record),
    do:
      record
      |> CodecNativePartialBranchCollections.strip()
      |> CodecFields.transform(@defaults, :strip)

  def upgrade(record),
    do:
      record
      |> CodecFields.transform(@defaults, :upgrade)
      |> CodecNativePartialBranchCollections.upgrade()

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :delete_collection) != nil

  def required?(_), do: false
end
