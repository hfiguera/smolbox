defmodule SmolBox.Embedded.UnbootedBranchBackingRelease do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
    BranchRequest,
    Shape,
    UnbootedBranchDisposal
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
      not is_struct(request["disposal"]) and UnbootedBranchDisposal.valid?(request["disposal"]) and
        BranchCanonical.current_head?(
          request["source"],
          get_in(request, ~w(disposal publication receipt))
        ) and
        request["child"] == get_in(request, ~w(disposal publication change child))

  defp identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["quiesced"] == true and request["backing_removed"] == true and distinct?(request) and
        request["request_sha256"] == request_digest(request)

  defp distinct?(request),
    do:
      request["operation_id"] not in [
        get_in(request, ~w(disposal request operation_id)),
        get_in(request, ~w(disposal creation child operation_id)),
        get_in(request, ~w(disposal creation initial_release operation_id))
      ]

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-unbooted-branch-backing-request-v1",
        BranchCanonical.ordered(request["disposal"], :unbooted_disposal),
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

  def approval(request), do: get_in(request, ~w(disposal creation approval))
  def platform(request), do: get_in(request, ~w(disposal publication change platform))
end
