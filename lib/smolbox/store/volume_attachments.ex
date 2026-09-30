defmodule SmolBox.Store.VolumeAttachments do
  @moduledoc false
  alias SmolBox.{Mount, Validation}
  def valid?(%{spec: %{volumes: []}} = m), do: m.mounts == [] and m.volume_worker_id == nil

  def valid?(%{mounts: []} = m),
    do: m.worker_id == nil and m.volume_worker_id == nil and m.state == :accepted

  def valid?(m) do
    Mount.canonical?(m.mounts) and length(m.mounts) == length(m.spec.volumes) and
      Validation.identifier?(m.volume_worker_id) and m.worker_id in [nil, m.volume_worker_id] and
      Enum.all?(Enum.zip(m.mounts, m.spec.volumes), fn {mount, ref} ->
        mount.target == ref.target and mount.readonly == ref.readonly
      end)
  end
end
