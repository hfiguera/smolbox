defmodule SmolBox.Store.CodecNativeMounts do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{SmolBox.ManagedMachine => [native_mounts: []]}
  def required?(%SmolBox.ManagedMachine{native_mounts: mounts}), do: mounts != []

  def required?(%{backend_assignment: %{creation: creation}}),
    do: Map.has_key?(creation, "volume_mounts")

  def required?(_), do: false
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
end
