defmodule SmolBox.Store.CodecNativeUnbootedBranchBackings do
  @moduledoc false
  # A new origin-specific backing request uses existing fields; previous readers
  # must still reject it rather than decoding it as ordinary retirement.
  def required?(%{branch: %{state: :backing_pending}}), do: true

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :disposal) != nil and Map.get(authority, :backing) != nil

  def required?(_), do: false
end
