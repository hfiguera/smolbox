defmodule SmolBox.Embedded.PartialBranchDisposal do
  @moduledoc """
  Original pre-handoff disposal after acknowledged original-child collection.

  SDK deletion and later positive absence have distinct completion provenance.
  This historical proof grants no readiness, source liveness, terminal-job
  handoff, dependency retirement or backing release.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    BranchRequest,
    PartialBranchCollection,
    PartialBranchDisposalContext,
    Shape
  }

  alias SmolBox.Validation
  @enforce_keys [:schema, :completion, :request, :publication, :disposal_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema, :completion]}
  defstruct @enforce_keys ++ [release: nil]
  @type t :: %__MODULE__{}

  def request?(value),
    do:
      Shape.keys?(value, ~w(collection_request collection operation_id request_sha256 quiesced)) and
        PartialBranchCollection.matches?(value["collection"], value["collection_request"]) and
        BranchRequest.release?(Map.take(value, ~w(operation_id request_sha256))) and
        value["quiesced"] == true and distinct_action?(value) and
        value["request_sha256"] == request_digest(value) and
        byte_size(Jason.encode!(value)) <= 24 * 1024

  defp distinct_action?(value),
    do:
      value["operation_id"] != value["collection"]["operation_id"] and
        value["operation_id"] != get_in(value, ~w(collection_request creation child operation_id)) and
        value["operation_id"] !=
          get_in(value, ~w(collection_request creation initial_release operation_id))

  def request_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-disposal-request-v1",
        BranchCanonical.ordered(value["collection_request"], :partial_collection_request),
        BranchCanonical.ordered(value["collection"], :partial_collection),
        value["operation_id"],
        value["quiesced"]
      ])

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(__MODULE__, Map.new(value, fn {k, v} -> {String.to_existing_atom(k), v} end))},
      else: :error
  end

  def to_wire(%__MODULE__{} = proof) do
    value = Map.new(Map.from_struct(proof), fn {k, v} -> {Atom.to_string(k), v} end)
    if proof.release == nil, do: Map.delete(value, "release"), else: value
  end

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value) when is_map(value),
    do:
      Shape.keys?(
        Map.delete(value, "release"),
        ~w(schema completion request publication disposal_sha256 proof_sha256)
      ) and
        request?(value["request"]) and BranchPublication.valid?(value["publication"]) and
        PartialBranchDisposalContext.valid?(value) and proof_fields?(value)

  def valid?(_), do: false

  defp proof_fields?(value),
    do:
      value["schema"] === 1 and value["completion"] in ~w(deleted resolved_absent) and
        Validation.digest?(value["disposal_sha256"]) and
        value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 48 * 1024

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-disposal-proof-v1",
        value["schema"],
        value["completion"],
        BranchCanonical.ordered(value["request"], :partial_disposal_request),
        BranchCanonical.ordered(value["publication"], :publication),
        if(value["release"] != nil,
          do: BranchCanonical.ordered(value["release"], :child_release)
        ),
        value["disposal_sha256"]
      ])

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do: valid?(proof) and request?(request) and proof["request"] == request

  def approval(request), do: get_in(request, ~w(collection_request creation approval))
end
