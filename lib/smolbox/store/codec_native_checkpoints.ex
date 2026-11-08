defmodule SmolBox.Store.CodecNativeCheckpoints do
  @moduledoc false
  alias SmolBox.Backend.Assignment

  # Restore-source intent is distinct from HTTP checkpoint records and from
  # registry/OCI material. Capture/export/branch histories have separate gates.
  def reader, do: 1

  def required?(%{
        backend_assignment: %Assignment{creation: %{"source" => %{"kind" => "checkpoint"}}}
      }),
      do: true

  def required?(_record), do: false
end
