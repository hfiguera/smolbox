defmodule SmolBox.Store.CodecGrowth do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{
    SmolBox.Embedded.Identity => [transition: nil],
    SmolBox.DiskExpansion => [native_transition: nil]
  }

  def reader, do: 1

  def required?(%SmolBox.ManagedMachine{
        backend_assignment: %{version: 2},
        disk_expansions: history
      }),
      do: history != %{}

  def required?(%SmolBox.Execution{
        backend_assignment: %{version: 2},
        created_machine: %{backend_identity: %{transition: transition}} = machine,
        spec: %{profile: profile}
      }),
      do:
        transition != nil or machine.storage_gb != profile.storage_gb or
          machine.overlay_gb != profile.overlay_gb

  def required?(_record), do: false
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
end
