defmodule SmolBox.Store.CodecNativePartialBranchRetirements do
  @moduledoc false
  # Existing fields gain distinct original partial-child authority. No defaults
  # change; earlier disposal envelopes must reject this retirement proof.
  def reader, do: 1

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do:
      Map.get(authority, :partial_disposal) != nil and
        (Map.get(authority, :retirement) != nil or Map.get(authority, :backing) != nil)

  def required?(_), do: false
end
