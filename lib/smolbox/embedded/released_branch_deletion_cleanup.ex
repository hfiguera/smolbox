defmodule SmolBox.Embedded.ReleasedBranchDeletionCleanup do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    BranchRequest,
    ReleasedBranchDeletionResolution,
    Shape
  }

  @request_maximum 132 * 1024

  def request?(request),
    do:
      Shape.keys?(request, ~w(completion release child operation_id request_sha256 quiesced)) and
        BranchCompletion.wire?(request["completion"]) and
        BranchReleaseTransition.valid?(request["release"]) and
        Shape.receipt?(request["child"], 2) and request["quiesced"] == true and
        release_bound?(request) and
        request_identity?(request) and byte_size(Jason.encode!(request)) <= @request_maximum

  defp release_bound?(request),
    do:
      request["release"]["previous"] == get_in(request, ~w(completion publication change child)) and
        request["release"]["change"]["binding"] ==
          get_in(request, ~w(completion publication change child_origin)) and
        request["release"]["change"]["identity_sha256"] ==
          request["completion"]["identity_sha256"] and
        request["child"] == request["release"]["receipt"] and
        (request["completion"]["held"] == true or
           request["completion"]["release"] == request["release"])

  defp request_identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] != get_in(request, ~w(release change request operation_id)) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        request["request_sha256"] == request_digest(request)

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-released-child-delete-cleanup-request-v1",
        BranchCanonical.ordered(request["completion"], :completion),
        BranchCanonical.ordered(request["release"], :child_release),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value), do: ReleasedBranchDeletionResolution.from_wire(value)
  def to_wire(value), do: ReleasedBranchDeletionResolution.to_wire(value)
  def valid?(value), do: ReleasedBranchDeletionResolution.valid?(value)

  def matches?(%ReleasedBranchDeletionResolution{} = proof, request),
    do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and proof["child"] == request["child"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"] and
        proof["completion_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)) and
        proof["release_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["release"], :child_release))

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))
end
