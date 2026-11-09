defmodule SmolBox.Embedded.BranchDeletionContinuation do
  @moduledoc """
  Acknowledgement of the original collected child's completed delete continuation.

  The shared engine issues it only from an original returned worker and exact
  protected Deleted continuation record. It cannot be inferred from namespace
  absence and releases neither source dependency nor persistent backing.
  Inspect output omits native receipt and request identity fields.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchDeletionResolution}
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
  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)
  def to_wire(%__MODULE__{} = value), do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      BranchDeletionResolution.valid_wire?(
        value,
        "smolbox-held-child-delete-continuation-proof-v1"
      )
end
