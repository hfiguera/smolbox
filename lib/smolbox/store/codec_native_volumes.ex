defmodule SmolBox.Store.CodecNativeVolumes do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{SmolBox.Volume => [native_authority: nil]}

  def required?(%SmolBox.Volume{native_authority: authority}), do: authority != nil
  def required?(_), do: false
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
end
