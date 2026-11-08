defmodule SmolBox.Embedded.HeldBranchReleaseRequest do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    BranchRequest,
    Shape
  }

  def from_authority(authority),
    do: %{
      "completion" => BranchCompletion.to_wire(authority.completion),
      "source" => authority.release.source,
      "request" => authority.release.request
    }

  def valid?(value),
    do:
      Shape.keys?(value, ~w(completion source request)) and
        BranchCompletion.wire?(value["completion"]) and value["completion"]["held"] == true and
        Shape.receipt?(value["source"], 2) and BranchRequest.release?(value["request"]) and
        BranchCanonical.origin(value["source"]) ==
          BranchCanonical.origin(value["completion"]["publication"]["previous"]) and
        value["request"]["operation_id"] !=
          value["completion"]["publication"]["change"]["child_origin"]["intent"]["child"][
            "operation_id"
          ] and
        bounded?(value)

  def matches?(proof, request) do
    with true <- valid?(request), {:ok, proof} <- BranchReleaseTransition.from_wire(proof) do
      completion = request["completion"]

      proof.change["mode"] == "explicit" and proof.previous == completion["child"] and
        proof.change["request"] == request["request"] and
        proof.change["binding"] == completion["publication"]["change"]["child_origin"] and
        proof.change["identity_sha256"] == completion["identity_sha256"]
    else
      _ -> false
    end
  end

  def approval(request),
    do: request["completion"]["publication"]["change"]["child_origin"]["intent"]["approval"]

  def platform(request), do: request["completion"]["publication"]["change"]["platform"]
  defp bounded?(value), do: byte_size(Jason.encode!(value)) <= 68 * 1024
end
