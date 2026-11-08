defmodule SmolBox.Embedded.BranchCreation do
  @moduledoc false
  alias SmolBox.Embedded.{BranchReleaseTransition, BranchRequest, CheckpointContract, Shape}
  alias SmolBox.Validation

  # A branch assignment is not a fresh pack/OCI/checkpoint creation request.
  # The inherited artifact is metadata; only its frozen branch request dispatches.
  def valid?(create),
    do:
      Shape.keys?(
        create,
        ~w(name owner_token incarnation branch artifact_identity resources labels)
      ) and
        BranchRequest.valid?(create["branch"]) and Shape.resources?(create["resources"]) and
        create["labels"] == %{} and artifact?(create["artifact_identity"]) and
        Enum.all?(
          ~w(name owner_token incarnation),
          &(create[&1] == create["branch"]["child"][&1])
        )

  def artifact?(artifact),
    do:
      (Shape.keys?(artifact, ~w(id sha256 architecture)) and Shape.id?(artifact["id"]) and
         Validation.digest?(artifact["sha256"]) and artifact["architecture"] in ~w(aarch64 x86_64)) or
        CheckpointContract.source?(artifact)

  def matches?(create, spec),
    do:
      valid?(create) and create["artifact_identity"] == spec.artifact and
        create["resources"] == resources(spec.profile) and spec.profile.network == :offline and
        Map.get(spec, :ports, []) == [] and Map.get(spec, :volumes, []) == [] and
        Map.get(spec, :workload) == nil and not Map.get(spec, :checkpointable, false)

  def from_request(request, artifact, profile),
    do:
      Map.merge(Map.take(request["child"], ~w(name owner_token incarnation)), %{
        "branch" => request,
        "artifact_identity" => artifact,
        "resources" => resources(profile),
        "labels" => %{}
      })

  def command?(record) do
    request = record.backend_assignment.creation["branch"]

    case record.created_machine do
      %{backend_identity: %{transition: %BranchReleaseTransition{} = proof}} ->
        intent = proof.change["binding"]["intent"]

        intent["source"] == request["source"] and intent["child"] == request["child"] and
          intent["approval"] == request["approval"] and
          (proof.change["mode"] == "explicit" or
             proof.change["request"] == request["initial_release"])

      _ ->
        false
    end
  end

  defp resources(profile),
    do: %{
      "cpus" => profile.cpus,
      "memory_mib" => profile.memory_mb,
      "storage_gib" => profile.storage_gb,
      "overlay_gib" => profile.overlay_gb
    }
end
