defmodule SmolBox.Store.CodecNativeSources do
  @moduledoc false
  alias SmolBox.Backend.Assignment

  def reader, do: 1

  def required?(%{backend_assignment: %Assignment{creation: creation}} = record)
      when is_map(creation),
      do:
        Map.has_key?(creation, "source") or
          match?(%{spec: %{command: %SmolBox.ImagePull{}}}, record)

  def required?(_record), do: false
end
