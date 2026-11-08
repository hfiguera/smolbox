defmodule SmolBox.Store.CodecNativeCaptureAbortSources do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Store.CodecFields
  @defaults %{SmolBox.CheckpointCapture => [native_abort_source: nil]}
  def reader, do: 1

  def strip(record),
    do:
      record
      |> SmolBox.Store.CodecNativeExports.strip()
      |> CodecFields.transform(@defaults, :strip)

  def upgrade(record),
    do:
      record
      |> CodecFields.transform(@defaults, :upgrade)
      |> SmolBox.Store.CodecNativeExports.upgrade()

  def required?(%{backend_assignment: %Assignment{version: 2}} = record), do: contains?(record)
  def required?(_), do: false
  defp contains?(%SmolBox.CheckpointCapture{native_abort_source: proof}), do: proof != nil

  defp contains?(value) when is_map(value),
    do: CodecFields.any_value?(value, &contains?/1)

  defp contains?([head | tail]), do: contains?(head) or contains?(tail)
  defp contains?(value) when is_tuple(value), do: value |> Tuple.to_list() |> contains?()
  defp contains?(_), do: false
end
