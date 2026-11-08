defmodule SmolBox.Embedded.PartialBranchBackingRelease do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
    BranchRequest,
    PartialBranchDisposal,
    Shape
  }

  def request?(request),
    do:
      Shape.keys?(
        request,
        ~w(disposal source child operation_id request_sha256 quiesced backing_removed)
      ) and
        binding?(request) and identity?(request) and
        byte_size(Jason.encode!(request)) <= 80 * 1024

  defp binding?(request),
    do:
      not is_struct(request["disposal"]) and PartialBranchDisposal.valid?(request["disposal"]) and
        head?(request["source"], get_in(request, ~w(disposal publication receipt))) and
        request["child"] == child_head(request)

  defp child_head(request),
    do:
      get_in(request, ~w(disposal release receipt)) ||
        get_in(request, ~w(disposal publication change child))

  defp identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["quiesced"] == true and request["backing_removed"] == true and distinct?(request) and
        request["request_sha256"] == request_digest(request)

  defp head?(current, expected),
    do:
      Shape.receipt?(current, 2) and current["material"] != nil and
        BranchCanonical.origin(current) == BranchCanonical.origin(expected) and
        current["material"]["revision"] >= expected["material"]["revision"] and
        (current["material"]["revision"] != expected["material"]["revision"] or
           current["material"] == expected["material"]) and
        (current["material"]["revision"] != 0 or BranchCanonical.root?(current))

  defp distinct?(request),
    do:
      request["operation_id"] not in [
        get_in(request, ~w(disposal request operation_id)),
        get_in(request, ~w(disposal request collection_request creation child operation_id)),
        get_in(request, ~w(disposal request collection_request operation_id)),
        get_in(request, ~w(disposal release change request operation_id)),
        get_in(
          request,
          ~w(disposal request collection_request creation initial_release operation_id)
        )
      ]

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-backing-request-v1",
        BranchCanonical.ordered(request["disposal"], :partial_disposal),
        BranchCanonical.ordered(request["source"], :receipt),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"],
        request["backing_removed"]
      ])

  def matches?(%BranchBackingRelease{} = proof, request),
    do: matches?(BranchBackingRelease.to_wire(proof), request)

  def matches?(proof, request),
    do:
      BranchBackingRelease.valid?(proof) and request?(request) and
        proof["publication"] == request["disposal"]["publication"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"]

  def approval(request),
    do: get_in(request, ~w(disposal request collection_request creation approval))

  def epoch(request),
    do: get_in(request, ~w(disposal publication change child_origin intent epoch))

  def platform(request), do: get_in(request, ~w(disposal publication change platform))
end
