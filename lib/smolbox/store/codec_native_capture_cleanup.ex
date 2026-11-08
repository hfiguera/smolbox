defmodule SmolBox.Store.CodecNativeCaptureCleanup do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Store.{CodecFields, CodecNativeCaptureAbortSources}
  @defaults %{SmolBox.CheckpointCapture => [native_source_receipt: nil, native_cleanup: nil]}
  def reader, do: 1

  def strip(record),
    do:
      record |> CodecNativeCaptureAbortSources.strip() |> CodecFields.transform(@defaults, :strip)

  def upgrade(record),
    do:
      record
      |> CodecFields.transform(@defaults, :upgrade)
      |> CodecNativeCaptureAbortSources.upgrade()

  def required?(%{backend_assignment: %Assignment{version: 2}} = record), do: contains?(record)
  def required?(_), do: false

  defp contains?(%SmolBox.CheckpointCapture{
         native_source_receipt: source,
         native_cleanup: cleanup
       }),
       do: source != nil or cleanup != nil

  defp contains?(value) when is_map(value),
    do: CodecFields.any_value?(value, &contains?/1)

  defp contains?([head | tail]), do: contains?(head) or contains?(tail)
  defp contains?(value) when is_tuple(value), do: value |> Tuple.to_list() |> contains?()
  defp contains?(_), do: false
end
