defmodule SmolBox.Embedded.ReleasedBranchDeletionCleanup do
  @moduledoc false
  alias SmolBox.Embedded.ReleasedBranchDeletionResolution
  @request_domain "smolbox-released-child-delete-cleanup-request-v1"

  def request?(request), do: ReleasedBranchDeletionResolution.request?(request, @request_domain)

  def request_digest(request),
    do: ReleasedBranchDeletionResolution.request_digest(request, @request_domain)

  def from_wire(value), do: ReleasedBranchDeletionResolution.from_wire(value)
  def to_wire(value), do: ReleasedBranchDeletionResolution.to_wire(value)
  def valid?(value), do: ReleasedBranchDeletionResolution.valid?(value)

  def matches?(%ReleasedBranchDeletionResolution{} = proof, request),
    do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and
        ReleasedBranchDeletionResolution.proof_matches?(proof, request)

  defdelegate platform(request), to: ReleasedBranchDeletionResolution
  defdelegate approval(request), to: ReleasedBranchDeletionResolution
end
