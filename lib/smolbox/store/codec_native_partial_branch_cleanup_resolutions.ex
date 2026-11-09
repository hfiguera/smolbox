defmodule SmolBox.Store.CodecNativePartialBranchCleanupResolutions do
  @moduledoc false
  alias SmolBox.Embedded.NativePartialBranchCleanup
  alias SmolBox.Store.CodecFields
  @defaults %{NativePartialBranchCleanup => [unneeded: nil]}
  def reader, do: 1

  def transform(record, mode),
    do: CodecFields.transform_optional(record, @defaults, mode, &required?/1)

  def required?(%{branch: %{native_authority: %{partial_disposal: %{cleanup: cleanup}}}})
      when is_map(cleanup),
      do: Map.get(cleanup, :unneeded) != nil

  def required?(_), do: false
end
