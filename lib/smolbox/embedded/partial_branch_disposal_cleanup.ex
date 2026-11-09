defmodule SmolBox.Embedded.PartialBranchDisposalCleanup do
  @moduledoc """
  Exact acknowledgement of original collected partial-child residual cleanup.

  Cleanup requires a separate immutable request and a resolved-absent disposal.
  This proof grants no SDK deletion retry, readiness, source liveness, dependency
  retirement or backing release.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchRequest, PartialBranchDisposal, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :request, :disposal, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def request?(value),
    do:
      Shape.keys?(value, ~w(disposal_request operation_id request_sha256 quiesced)) and
        PartialBranchDisposal.request?(value["disposal_request"]) and
        BranchRequest.release?(Map.take(value, ~w(operation_id request_sha256))) and
        value["quiesced"] == true and distinct?(value) and
        value["request_sha256"] == request_digest(value) and
        byte_size(Jason.encode!(value)) <= 28 * 1024

  defp distinct?(value),
    do:
      value["operation_id"] not in [
        get_in(value, ~w(disposal_request operation_id)),
        get_in(value, ~w(disposal_request collection_request operation_id)),
        get_in(value, ~w(disposal_request collection_request creation child operation_id)),
        get_in(
          value,
          ~w(disposal_request collection_request creation initial_release operation_id)
        )
      ]

  def request_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-disposal-cleanup-request-v1",
        BranchCanonical.ordered(value["disposal_request"], :partial_disposal_request),
        value["operation_id"],
        value["quiesced"]
      ])

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value), do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value) when is_map(value),
    do:
      Shape.keys?(value, ~w(schema request disposal proof_sha256)) and
        request?(value["request"]) and context?(value) and proof_fields?(value)

  def valid?(_), do: false

  defp context?(value),
    do:
      not is_struct(value["disposal"]) and PartialBranchDisposal.valid?(value["disposal"]) and
        value["disposal"]["request"] == value["request"]["disposal_request"] and
        value["disposal"]["completion"] == "resolved_absent" and
        get_in(value, ~w(disposal release change request operation_id)) !=
          value["request"]["operation_id"]

  defp proof_fields?(value),
    do:
      value["schema"] === 1 and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 80 * 1024

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-disposal-cleanup-v1",
        value["schema"],
        BranchCanonical.ordered(value["request"], :partial_cleanup_request),
        BranchCanonical.ordered(value["disposal"], :partial_disposal)
      ])

  def matches?(proof, request),
    do: BranchCanonical.request_proof_matches?(proof, request, __MODULE__, &request?/1)

  def approval(request),
    do: get_in(request, ~w(disposal_request collection_request creation approval))
end
