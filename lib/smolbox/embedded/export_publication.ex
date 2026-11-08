defmodule SmolBox.Embedded.ExportPublication do
  @moduledoc false
  alias SmolBox.Embedded.{ExportContract, Shape}
  alias SmolBox.Validation
  @enforce_keys [:schema, :source, :operation_id, :request_sha256, :identity, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  def from_wire(value) do
    if Shape.keys?(value, ~w(schema source operation_id request_sha256 identity proof_sha256)) do
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
        Validation.digest?(proof.request_sha256) and ExportContract.identity?(proof.identity) and
        Validation.digest?(proof.proof_sha256) and
        proof.proof_sha256 ==
          ExportContract.proof_digest(
            proof.source,
            proof.operation_id,
            proof.request_sha256,
            proof.identity
          )

  def valid?(_), do: false

  def bound?(proof, source, id, request_sha256),
    do:
      valid?(proof) and proof.source == source and proof.operation_id == id and
        proof.request_sha256 == request_sha256

  def bound_request?(proof, source, id, request),
    do:
      ExportContract.request?(request) and bound?(proof, source, id, request["request_sha256"]) and
        proof.identity["destination_id"] == request["destination_id"] and
        proof.identity["destination_sha256"] == request["destination_sha256"] and
        proof.identity["tag"] == request["tag"] and
        proof.identity["size_bytes"] <= request["max_artifact_bytes"]
end
