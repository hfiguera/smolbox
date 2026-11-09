defmodule SmolBox.Store.CodecNativePartialBranchBackings do
  @moduledoc false
  def reader, do: 1

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :partial_disposal) != nil and Map.get(authority, :backing) != nil

  def required?(_), do: false
end
