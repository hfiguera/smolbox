defmodule SmolBox.Embedded.BranchDeletionContinuation do
  @moduledoc """
  Acknowledgement of the original collected child's completed delete continuation.

  The shared engine issues it only from an original returned worker and exact
  protected Deleted continuation record. It cannot be inferred from namespace
  absence and releases neither source dependency nor persistent backing.
  Inspect output omits native receipt and request identity fields.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchRequest, Shape}
  alias SmolBox.Validation
  @enforce_keys [:schema, :child, :operation_id, :request_sha256, :deletion_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: 1,
          child: map(),
          operation_id: String.t(),
          request_sha256: String.t(),
          deletion_sha256: String.t(),
          proof_sha256: String.t()
        }
  @proof_maximum 4096

  def from_wire(value) do
    if Shape.keys?(
         value,
         ~w(schema child operation_id request_sha256 deletion_sha256 proof_sha256)
       ) and valid?(value),
       do:
         {:ok,
          struct!(
            __MODULE__,
            Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
          )},
       else: :error
  end

  def to_wire(%__MODULE__{} = value),
    do: Map.new(Map.from_struct(value), fn {key, field} -> {Atom.to_string(key), field} end)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      Shape.keys?(
        value,
        ~w(schema child operation_id request_sha256 deletion_sha256 proof_sha256)
      ) and
        value["schema"] === 1 and Shape.receipt?(value["child"], 2) and
        BranchCanonical.root?(value["child"]) and
        BranchRequest.release?(Map.take(value, ~w(operation_id request_sha256))) and
        Validation.digest?(value["deletion_sha256"]) and
        value["proof_sha256"] ==
          BranchCanonical.digest([
            "smolbox-held-child-delete-continuation-proof-v1",
            1,
            BranchCanonical.ordered(value["child"], :receipt),
            value["operation_id"],
            value["request_sha256"],
            value["deletion_sha256"]
          ]) and byte_size(Jason.encode!(value)) <= @proof_maximum
end
