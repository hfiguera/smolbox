defmodule SmolBox.Embedded.UnbootedBranchBackingRelease do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
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
    do: BranchBackingRelease.disposal_request_identity?(request, &distinct?/1, &request_digest/1)

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

  def matches?(proof, request),
    do: BranchBackingRelease.matches_disposal?(proof, request, &request?/1)

  def approval(request), do: get_in(request, ~w(disposal creation approval))
  def platform(request), do: get_in(request, ~w(disposal publication change platform))
end
