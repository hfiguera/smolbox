defmodule SmolBox.Store.CodecNativeCaptures do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Store.{CodecFields, CodecNativeCaptureCleanup}

  @defaults %{
    SmolBox.Embedded.Identity => [material_history: nil],
    SmolBox.CheckpointCapture => [native_transition: nil]
  }
  def reader, do: 1

  def strip(record),
    do: record |> CodecNativeCaptureCleanup.strip() |> CodecFields.transform(@defaults, :strip)

  def upgrade(record),
    do:
      record |> CodecFields.transform(@defaults, :upgrade) |> CodecNativeCaptureCleanup.upgrade()

  def required?(%{backend_assignment: %Assignment{version: 2}} = record), do: history?(record)
  def required?(_), do: false
  defp history?(%{captures: captures}) when map_size(captures) > 0, do: true

  defp history?(%{created_machine: %{backend_identity: %{material_history: history}}})
       when is_list(history), do: true

  defp history?(_), do: false
end
