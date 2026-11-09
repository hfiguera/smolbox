defmodule SmolBox.Embedded.BranchDeletionResolution do
  @moduledoc """
  Request-bound positive absence after an original held-child deletion.

  The shared engine requires retained original completion and deletion context,
  a returned worker, original collection and SDK row/reservation/directory absence.
  It neither invokes SDK deletion nor removes files. Stores must additionally bind
  the request to the saved management intent/version before resolving uncertainty.
  Dependency retirement and backing release require their separate proofs.
  Inspect output omits native receipt and request identity fields.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchCompletion, BranchRequest, Shape}
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
  @request_maximum 68 * 1024
  @proof_maximum 4096

  def request?(request),
    do:
      Shape.keys?(request, ~w(completion child operation_id request_sha256 quiesced)) and
        BranchCompletion.wire?(request["completion"]) and request["completion"]["held"] == true and
        request["completion"]["release"] == nil and Shape.receipt?(request["child"], 2) and
        request["child"] == request["completion"]["child"] and request["quiesced"] == true and
        request_identity?(request) and byte_size(Jason.encode!(request)) <= @request_maximum

  defp request_identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        request["request_sha256"] == request_digest(request)

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-held-child-delete-request-v1",
        BranchCanonical.ordered(request["completion"], :completion),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)
  def to_wire(%__MODULE__{} = value), do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value), do: valid_wire?(value, "smolbox-held-child-delete-resolution-v1")

  @doc false
  def valid_wire?(value, domain),
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
            domain,
            1,
            BranchCanonical.ordered(value["child"], :receipt),
            value["operation_id"],
            value["request_sha256"],
            value["deletion_sha256"]
          ]) and byte_size(Jason.encode!(value)) <= @proof_maximum

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and proof["child"] == request["child"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"]

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))
end
