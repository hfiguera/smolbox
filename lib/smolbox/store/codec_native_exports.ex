defmodule SmolBox.Store.CodecNativeExports do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{
    SmolBox.Export => [native_authority: nil],
    SmolBox.ExportReceipt => [native_publication: nil]
  }
  def reader, do: 1
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
  def required?(%{backend_assignment: %{version: 2}, exports: exports}), do: map_size(exports) > 0
  def required?(_), do: false
end
