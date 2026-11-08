defmodule SmolBox.Store.CodecNativeBranches do
  @moduledoc false
  alias SmolBox.Embedded.{BranchPublication, BranchReleaseTransition}

  def reader, do: 1
  def required?(%{backend_assignment: %{version: 2}} = record), do: contains?(record)
  def required?(_), do: false

  defp contains?(%BranchPublication{}), do: true
  defp contains?(%BranchReleaseTransition{}), do: true
  defp contains?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&contains?/1)
  defp contains?([head | tail]), do: contains?(head) or contains?(tail)
  defp contains?(value) when is_tuple(value), do: value |> Tuple.to_list() |> contains?()
  defp contains?(_), do: false
end
