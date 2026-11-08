defmodule SmolBox.Store.CodecVolumes do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{
    SmolBox.Machine => [mounts: []],
    SmolBox.ManagedMachineSpec => [volumes: []],
    SmolBox.ManagedMachine => [mounts: [], volume_worker_id: nil]
  }
  # Recursively strip only empty defaults for older envelopes; new volume state
  # always requires v15. Old envelopes may not smuggle even empty new fields.
  def required?(%SmolBox.Volume{}), do: true
  def required?(%SmolBox.ManagedMachine{spec: %{volumes: refs}}), do: refs != []
  def required?(%SmolBox.Execution{created_machine: %{mounts: mounts}}), do: mounts != []
  def required?(_), do: false

  def strip(term), do: CodecFields.transform(term, @defaults, :strip)
  def upgrade(term), do: CodecFields.transform(term, @defaults, :upgrade)
end
