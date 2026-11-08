defmodule SmolBox.Embedded.UnbootedBranchDisposal do
  @moduledoc """
  Historical original-job disposal proof for a child that never entered boot.
  Successful SDK return and later observed absence retain distinct provenance.
  This is not boot readiness, backing removal or authority to replay SDK work.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchPublication, BranchRequest, Shape}
  alias SmolBox.Validation

  @enforce_keys [
    :schema,
    :completion,
    :creation,
    :request,
    :publication,
    :disposal_sha256,
    :proof_sha256
  ]
  @derive {Inspect, only: [:schema, :completion]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def request?(request),
    do:
      Shape.keys?(request, ~w(creation request)) and
        intent?(request["request"], request["creation"]) and
        byte_size(Jason.encode!(request)) <= 20 * 1024

  def intent?(request, creation),
    do:
      Shape.keys?(request, ~w(operation_id request_sha256 quiesced)) and
        BranchRequest.valid?(creation) and byte_size(Jason.encode!(creation)) <= 16 * 1024 and
        BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["quiesced"] == true and
        request["operation_id"] != creation["child"]["operation_id"] and
        request["operation_id"] != get_in(creation, ~w(initial_release operation_id)) and
        request["request_sha256"] == request_digest(request, creation)

  def request_digest(request, creation),
    do:
      BranchCanonical.digest([
        "smolbox-unbooted-branch-disposal-request-v1",
        BranchCanonical.ordered(creation, :creation_request),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = proof),
    do: Map.new(Map.from_struct(proof), fn {key, value} -> {Atom.to_string(key), value} end)

  def valid?(%__MODULE__{} = proof),
    do: Validation.struct_shape?(proof, __MODULE__) and valid?(to_wire(proof))

  def valid?(proof),
    do:
      Shape.keys?(
        proof,
        ~w(schema completion creation request publication disposal_sha256 proof_sha256)
      ) and
        proof["schema"] === 1 and proof["completion"] in ~w(deleted resolved_absent) and
        intent?(proof["request"], proof["creation"]) and
        BranchPublication.valid?(proof["publication"]) and
        Map.take(
          get_in(proof, ~w(publication change child_origin intent)),
          ~w(source child approval)
        ) ==
          Map.take(proof["creation"], ~w(source child approval)) and
        Validation.digest?(proof["disposal_sha256"]) and
        proof["proof_sha256"] == proof_digest(proof) and
        byte_size(Jason.encode!(proof)) <= 32 * 1024

  def proof_digest(proof),
    do:
      BranchCanonical.digest([
        "smolbox-unbooted-branch-disposal-proof-v1",
        proof["schema"],
        proof["completion"],
        BranchCanonical.ordered(proof["creation"], :creation_request),
        BranchCanonical.ordered(proof["request"], :unbooted_disposal_intent),
        BranchCanonical.ordered(proof["publication"], :publication),
        proof["disposal_sha256"]
      ])

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and
        proof["creation"] == request["creation"] and proof["request"] == request["request"]

  def approval(request), do: get_in(request, ~w(creation approval))
end
