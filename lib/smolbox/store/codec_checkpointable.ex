defmodule SmolBox.Store.CodecCheckpointable do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  def reader, do: 1

  def required?(%{backend_assignment: %Assignment{creation: creation}}) when is_map(creation),
    do: Map.has_key?(creation, "checkpointable")

  def required?(_record), do: false
end
