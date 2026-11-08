defmodule SmolBox.Embedded.MaterialProof do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  def valid?(proof) do
    Shape.keys?(proof, ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)) and
      proof["schema"] == 2 and Validation.integer?(proof["revision"], 0, 1024) and
      Validation.digest?(proof["record_sha256"]) and Validation.digest?(proof["chain_sha256"]) and
      operation?(proof)
  end

  defp operation?(%{"revision" => 0} = proof),
    do: proof["operation_id"] == nil and proof["request_sha256"] == nil

  defp operation?(proof),
    do: Shape.id?(proof["operation_id"]) and Validation.digest?(proof["request_sha256"])
end
