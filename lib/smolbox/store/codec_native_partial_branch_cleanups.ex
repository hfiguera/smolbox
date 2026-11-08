defmodule SmolBox.Store.CodecNativePartialBranchCleanups do
  @moduledoc false
  alias SmolBox.Embedded.NativePartialBranchDisposal
  alias SmolBox.Store.{CodecFields, CodecNativeCollectedBranchPublications}
  @defaults %{NativePartialBranchDisposal => [cleanup: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecNativeCollectedBranchPublications.strip()
    |> CodecFields.transform(@defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecFields.transform(@defaults, :upgrade)
    |> CodecNativeCollectedBranchPublications.upgrade()
  end

  def required?(%{branch: %{native_authority: %{partial_disposal: disposal}}})
      when is_map(disposal),
      do: Map.get(disposal, :cleanup) != nil

  def required?(_), do: false
end
