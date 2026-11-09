defmodule SmolBox.Store.CodecNativeCollectedBranchPublications do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.CodecFields
  @defaults %{NativeBranchAuthority => [collected_publication: nil]}
  def reader, do: 1

  def strip(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :upgrade)
  end

  def transform_predecessor(record, defaults, :strip, required?) do
    if required?.(record), do: raise(ArgumentError)

    record
    |> strip()
    |> CodecFields.transform(defaults, :strip)
  end

  def transform_predecessor(record, defaults, :upgrade, required?) do
    record
    |> CodecFields.transform_optional(defaults, :upgrade, required?)
    |> upgrade()
  end

  def required?(%{branch: %{native_authority: authority}}) when is_map(authority),
    do: Map.get(authority, :collected_publication) != nil

  def required?(_), do: false
end
