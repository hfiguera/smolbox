defmodule SmolBox.Embedded.ReleasedBranchDeletionContinuation do
  @moduledoc """
  Request-bound acknowledgement of original released-child deletion continuation.

  The shared engine permits only the original collected child's unentered final
  SDK deletion under its retained context and frozen continuation. Entered SDK
  deletion never repeats. This proof requires positive SDK completion and the
  original returned worker; explicit absence uses its separate resolution proof.
  Stores must bind accepted management/delete versions before native IO.
  Dependency retirement and backing release retain their separate proofs.
  Inspect output omits receipt and request identities.
  """
  alias SmolBox.Embedded.{BranchCanonical, ReleasedBranchDeletionResolution}
  alias SmolBox.Validation

  @enforce_keys [
    :schema,
    :child,
    :operation_id,
    :request_sha256,
    :completion_sha256,
    :release_sha256,
    :deletion_sha256,
    :proof_sha256
  ]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: 1,
          child: map(),
          operation_id: String.t(),
          request_sha256: String.t(),
          completion_sha256: String.t(),
          release_sha256: String.t(),
          deletion_sha256: String.t(),
          proof_sha256: String.t()
        }
  @request_domain "smolbox-released-child-delete-continuation-request-v1"
  @proof_domain "smolbox-released-child-delete-continuation-proof-v1"

  def request?(request), do: ReleasedBranchDeletionResolution.request?(request, @request_domain)

  def request_digest(request),
    do: ReleasedBranchDeletionResolution.request_digest(request, @request_domain)

  def from_wire(value),
    do: ReleasedBranchDeletionResolution.proof_from_wire(value, __MODULE__, @proof_domain)

  def to_wire(%__MODULE__{} = value), do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value), do: ReleasedBranchDeletionResolution.valid_wire?(value, @proof_domain)

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and
        ReleasedBranchDeletionResolution.proof_matches?(proof, request)

  defdelegate platform(request), to: ReleasedBranchDeletionResolution
  defdelegate approval(request), to: ReleasedBranchDeletionResolution
end
