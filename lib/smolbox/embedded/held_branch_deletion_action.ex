defmodule SmolBox.Embedded.HeldBranchDeletionAction do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchDeletionContinuation,
    BranchDeletionResolution,
    BranchRequest,
    Shape
  }

  @maximum 68 * 1024
  def request?(request, expected \\ nil),
    do:
      Shape.keys?(request, ~w(action completion child operation_id request_sha256 quiesced)) and
        request["action"] in ~w(continue cleanup) and
        (expected == nil or request["action"] == expected) and
        held_binding?(request) and identity?(request) and
        byte_size(Jason.encode!(request)) <= @maximum

  defp held_binding?(request),
    do:
      BranchCompletion.wire?(request["completion"]) and request["completion"]["held"] == true and
        request["completion"]["release"] == nil and Shape.receipt?(request["child"], 2) and
        request["child"] == request["completion"]["child"] and request["quiesced"] == true

  defp identity?(request),
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
        "smolbox-held-child-delete-action-v1",
        request["action"],
        BranchCanonical.ordered(request["completion"], :completion),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"]
      ])

  def matches?(proof, request, action) when action in ~w(continue cleanup),
    do: request?(request, action) and proof?(proof, action) and fields_match?(proof, request)

  def matches?(_, _, _), do: false
  defp proof?(proof, "continue"), do: BranchDeletionContinuation.valid?(proof)
  defp proof?(proof, "cleanup"), do: BranchDeletionResolution.valid?(proof)

  defp fields_match?(proof, request) when is_struct(proof),
    do: fields_match?(Map.from_struct(proof), request)

  defp fields_match?(%{child: child, operation_id: id, request_sha256: sha}, request),
    do:
      child == request["child"] and id == request["operation_id"] and
        sha == request["request_sha256"]

  defp fields_match?(proof, request),
    do:
      proof["child"] == request["child"] and proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"]

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))
end
