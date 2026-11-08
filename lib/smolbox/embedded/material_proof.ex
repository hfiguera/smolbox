defmodule SmolBox.Embedded.MaterialProof do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  defdelegate valid?(proof), to: Shape, as: :material_proof?
end
