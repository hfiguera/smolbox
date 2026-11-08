defmodule SmolBox.Store.CodecNativeCaptureResolutions do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Embedded.CaptureResolutionTransition

  def reader, do: 1
  def required?(%{backend_assignment: %Assignment{version: 2}} = record), do: contains?(record)
  def required?(_), do: false

  defp contains?(%CaptureResolutionTransition{}), do: true
  defp contains?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&contains?/1)
  defp contains?([head | tail]), do: contains?(head) or contains?(tail)
  defp contains?(value) when is_tuple(value), do: value |> Tuple.to_list() |> contains?()
  defp contains?(_), do: false
end
