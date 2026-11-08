defmodule SmolBox.Store.CodecNativePartialBranchCleanupResolutions do
  @moduledoc false
  alias SmolBox.Embedded.NativePartialBranchCleanup
  alias SmolBox.Store.CodecFields
  @defaults %{NativePartialBranchCleanup => [unneeded: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :upgrade)
  end

  def required?(%{branch: %{native_authority: %{partial_disposal: %{cleanup: cleanup}}}})
      when is_map(cleanup),
      do: Map.get(cleanup, :unneeded) != nil

  def required?(_), do: false
end
