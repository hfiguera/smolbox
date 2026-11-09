defmodule SmolBox.Embedded.BranchChildAbsence do
  @moduledoc """
  Request-bound evidence of an original native branch child's namespace absence.

  The shared engine issues this only after original enrollment collection and
  current SDK row, creation-reservation and directory absence checks. A custom
  store must additionally bind it to its saved completion, current child head,
  fingerprint and version in the atomic source/child retirement transaction.
  This historical observation does not delete anything or release backing.
  Inspect output omits its native receipt and ownership fields.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchCompletion, BranchRequest, Shape}
  alias SmolBox.Validation
  @enforce_keys [:schema, :request, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{schema: 1, request: map(), proof_sha256: String.t()}
  @maximum 68 * 1024

  def request?(request),
    do:
      Shape.keys?(request, ~w(completion child operation_id request_sha256 quiesced)) and
        BranchCompletion.wire?(request["completion"]) and Shape.receipt?(request["child"], 2) and
        request["quiesced"] == true and
        identity?(request) and bounded?(request)

  defp identity?(request),
    do:
      BranchCanonical.origin(request["child"]) ==
        BranchCanonical.origin(request["completion"]["child"]) and
        BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        (request["child"]["material"]["revision"] != 0 or BranchCanonical.root?(request["child"]))

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value), do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = proof),
    do: Validation.struct_shape?(proof, __MODULE__) and valid?(to_wire(proof))

  def valid?(proof),
    do:
      Shape.keys?(proof, ~w(schema request proof_sha256)) and proof["schema"] === 1 and
        request?(proof["request"]) and
        proof["proof_sha256"] ==
          BranchCanonical.digest([
            "smolbox-branch-child-absence-v1",
            1,
            BranchCanonical.ordered(proof["request"], :child_absence_request)
          ]) and bounded?(proof)

  def matches?(proof, request),
    do: BranchCanonical.request_proof_matches?(proof, request, __MODULE__, &request?/1)

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))

  defp bounded?(value), do: byte_size(Jason.encode!(value)) <= @maximum
end
