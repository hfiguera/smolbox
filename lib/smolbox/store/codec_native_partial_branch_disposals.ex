defmodule SmolBox.Store.CodecNativePartialBranchDisposals do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.CodecFields
  @defaults %{NativeBranchAuthority => [partial_disposal: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :upgrade)
  end

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :partial_disposal) != nil

  def required?(_), do: false
end
