defmodule SmolBox.Embedded.ExportStageCleanup do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation
  @enforce_keys [:schema, :source, :operation_id, :request_sha256, :stage_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  def from_wire(value) do
    if Shape.keys?(value, ~w(schema source operation_id request_sha256 stage_sha256)) do
      proof =
        struct!(
          __MODULE__,
          Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
        )

      if valid?(proof), do: {:ok, proof}, else: :error
    else
      :error
    end
  end

  def valid?(%__MODULE__{} = proof),
    do:
      Validation.struct_shape?(proof, __MODULE__) and proof.schema == 1 and
        Shape.receipt?(proof.source, 2) and proof.source["material"] != nil and
        Shape.id?(proof.operation_id) and
        Validation.digest?(proof.request_sha256) and Validation.digest?(proof.stage_sha256)

  def valid?(_), do: false

  def bound?(proof, source, id, request_sha256),
    do:
      valid?(proof) and proof.source == source and proof.operation_id == id and
        proof.request_sha256 == request_sha256
end
