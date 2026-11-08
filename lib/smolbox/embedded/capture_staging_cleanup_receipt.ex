defmodule SmolBox.Embedded.CaptureStagingCleanupReceipt do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureTransition, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :operation_id, :request, :stage_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  def from_wire(value) do
    if Shape.keys?(value, ~w(schema previous operation_id request stage_sha256)) do
      proof =
        struct!(
          __MODULE__,
          Map.new(value, fn {key, field} ->
            {String.to_existing_atom(key), field}
          end)
        )

      if valid?(proof), do: {:ok, proof}, else: :error
    else
      :error
    end
  end

  def valid?(%__MODULE__{} = proof),
    do:
      Validation.struct_shape?(proof, __MODULE__) and proof.schema == 1 and
        Shape.receipt?(proof.previous, 2) and proof.previous["material"] != nil and
        Shape.id?(proof.operation_id) and CaptureTransition.request?(proof.request) and
        Validation.digest?(proof.stage_sha256)

  def valid?(_), do: false

  def bound?(proof, previous, id, request),
    do:
      valid?(proof) and proof.previous == previous and proof.operation_id == id and
        proof.request == request
end
