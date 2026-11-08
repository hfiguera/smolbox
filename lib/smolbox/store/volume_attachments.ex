defmodule SmolBox.Store.VolumeAttachments do
  @moduledoc false
  alias SmolBox.Embedded.VolumeAttachment
  alias SmolBox.{Mount, Validation}

  def valid?(%{spec: %{volumes: []}} = m),
    do: m.mounts == [] and m.native_mounts == [] and m.volume_worker_id == nil

  def valid?(%{mounts: []} = m),
    do:
      m.worker_id == nil and m.volume_worker_id == nil and m.state == :accepted and
        m.native_mounts == []

  def valid?(m) do
    Mount.canonical?(m.mounts) and length(m.mounts) == length(m.spec.volumes) and
      Validation.identifier?(m.volume_worker_id) and m.worker_id in [nil, m.volume_worker_id] and
      Enum.all?(Enum.zip(m.mounts, m.spec.volumes), fn {mount, ref} ->
        mount.target == ref.target and mount.readonly == ref.readonly
      end) and native?(m)
  end

  defp native?(%{native_mounts: []}), do: true

  defp native?(m) do
    Validation.list?(m.native_mounts, 8) and length(m.native_mounts) == length(m.mounts) and
      Enum.all?(m.native_mounts, &VolumeAttachment.valid?/1) and
      same_authority?(m.native_mounts) and
      references?(m) and assignment?(m)
  end

  defp references?(m),
    do:
      Enum.all?(Enum.zip([m.native_mounts, m.mounts, m.spec.volumes]), fn {attachment, mount, ref} ->
        attachment.volume_key == {m.scope, ref.volume_id} and
          attachment.binding.target_id == m.volume_worker_id and
          attachment.target == mount.target and attachment.readonly == mount.readonly and
          VolumeAttachment.path(attachment) == mount.source
      end)

  defp same_authority?([first | _] = attachments),
    do:
      Enum.all?(attachments, fn attachment ->
        attachment.binding == first.binding and
          attachment.proof["account"] == first.proof["account"] and
          attachment.proof["backing"]["policy"] == first.proof["backing"]["policy"]
      end) and
        length(Enum.uniq_by(attachments, & &1.proof["backing"]["intent"]["worker_volume_id"])) ==
          length(attachments)

  defp assignment?(%{backend_assignment: nil, worker_id: nil}), do: true

  defp assignment?(%{backend_assignment: %{binding: binding}} = m),
    do: binding == hd(m.native_mounts).binding

  defp assignment?(_), do: false
end
