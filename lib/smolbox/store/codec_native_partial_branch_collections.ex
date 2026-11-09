defmodule SmolBox.Store.CodecNativePartialBranchCollections do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativePartialBranchDisposals}
  @defaults %{NativeBranchAuthority => [partial_collection: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecNativePartialBranchDisposals.transform(:strip)
    |> CodecFields.transform(@defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecFields.transform(@defaults, :upgrade)
    |> CodecNativePartialBranchDisposals.transform(:upgrade)
  end

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :partial_collection) != nil

  def required?(_), do: false
end
