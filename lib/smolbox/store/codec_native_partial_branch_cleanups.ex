defmodule SmolBox.Store.CodecNativePartialBranchCleanups do
  @moduledoc false
  alias SmolBox.Embedded.NativePartialBranchDisposal
  alias SmolBox.Store.CodecFields
  @defaults %{NativePartialBranchDisposal => [cleanup: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :upgrade)
  end

  def required?(%{branch: %{native_authority: %{partial_disposal: disposal}}})
      when is_map(disposal),
      do: Map.get(disposal, :cleanup) != nil

  def required?(_), do: false
end
