defmodule SmolBox.Embedded.PartialBranchDisposalContext do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, BranchReleaseTransition}
  def valid?(value), do: context?(value) and release?(value)

  defp context?(proof) do
    request = proof["request"]
    creation = request["collection_request"]["creation"]
    intent = get_in(proof, ~w(publication change child_origin intent))

    Map.take(intent, ~w(source child approval)) == Map.take(creation, ~w(source child approval)) and
      request["collection"]["publication_sha256"] ==
        BranchCanonical.digest(BranchCanonical.ordered(proof["publication"], :publication))
  end

  defp release?(%{"release" => release} = proof) when not is_nil(release) do
    request = proof["request"]
    initial = get_in(request, ~w(collection_request creation initial_release))

    BranchReleaseTransition.valid?(release) and
      release["change"]["request"]["operation_id"] != request["operation_id"] and
      release["previous"] == proof["publication"]["change"]["child"] and
      release["change"]["binding"] == proof["publication"]["change"]["child_origin"] and
      release["change"]["boot_sha256"] == request["collection"]["boot_sha256"] and
      (initial == nil or initial == release["change"]["request"])
  end

  defp release?(_), do: true
end
