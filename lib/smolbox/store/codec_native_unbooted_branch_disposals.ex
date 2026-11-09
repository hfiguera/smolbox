defmodule SmolBox.Store.CodecNativeUnbootedBranchDisposals do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativeBranchCollections}
  @defaults %{NativeBranchAuthority => [disposal: nil]}
  def strip(record) do
    if required?(record), do: raise(ArgumentError)
    record |> CodecNativeBranchCollections.strip() |> CodecFields.transform(@defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    record |> CodecFields.transform(@defaults, :upgrade) |> CodecNativeBranchCollections.upgrade()
  end

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :disposal) != nil

  def required?(_), do: false
end
