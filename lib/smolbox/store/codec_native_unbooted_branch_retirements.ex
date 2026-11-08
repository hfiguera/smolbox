defmodule SmolBox.Store.CodecNativeUnbootedBranchRetirements do
  @moduledoc false
  # Existing fields carry new origin-specific typed authority. No default changes
  # are needed, but v37 readers must never accept a relabeled v38 retirement.
  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do:
      Map.get(authority, :disposal) != nil and
        (Map.get(authority, :retirement) != nil or Map.get(authority, :backing) != nil)

  def required?(_), do: false
end
