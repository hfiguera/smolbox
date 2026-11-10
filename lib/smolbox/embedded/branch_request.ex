defmodule SmolBox.Embedded.BranchRequest do
  @moduledoc false
  alias SmolBox.{BranchReleaseEnv, Validation}
  alias SmolBox.Embedded.{BranchCanonical, Shape}

  def valid?(request) when is_map(request) do
    Shape.keys?(Map.delete(request, "initial_release"), ~w(source child approval)) and
      Shape.receipt?(request["source"], 2) and
      child?(request["child"], request["source"]) and approval?(request["approval"]) and
      activation?(request)
  end

  def valid?(_), do: false

  def approvals(%{branch_policies: policies, profiles: profiles}) do
    overheads = profiles |> Enum.map(& &1.host_overhead_mb) |> Enum.uniq()

    for policy <- policies, overhead <- overheads do
      %{
        "id" => policy.id,
        "host_overhead_mb" => overhead,
        "resources" =>
          Map.new(policy.resources, fn {key, value} -> {Atom.to_string(key), value} end)
      }
    end
  end

  def approval?(value),
    do:
      BranchCanonical.keys?(value, :approval) and Shape.id?(value["id"]) and
        Validation.integer?(value["host_overhead_mb"], 128, 16_384) and
        resources?(value["resources"])

  def resources?(value),
    do:
      BranchCanonical.keys?(value, :resources) and
        Enum.all?(~w(slots cpus memory_mb disk_gb), &Validation.integer?(value[&1], 1, 1_048_576))

  def child?(child, source),
    do:
      BranchCanonical.keys?(child, :child) and Shape.id?(child["operation_id"]) and
        Shape.id?(child["name"]) and Shape.hex?(child["owner_token"], 64) and
        Shape.hex?(child["incarnation"], 32) and child["idle"] == true and
        is_boolean(child["hold"]) and
        Enum.all?(~w(name owner_token incarnation), &(child[&1] != source[&1]))

  def release?(value) when is_map(value),
    do:
      Shape.keys?(Map.delete(value, "env"), ~w(operation_id request_sha256)) and
        (not Map.has_key?(value, "env") or BranchReleaseEnv.wire?(value["env"])) and
        Shape.id?(value["operation_id"]) and
        Validation.digest?(value["request_sha256"])

  def release?(_), do: false

  defp activation?(%{"child" => %{"hold" => true}} = request),
    do: not Map.has_key?(request, "initial_release")

  defp activation?(request),
    do:
      release?(request["initial_release"]) and
        not Map.has_key?(request["initial_release"], "env") and
        request["initial_release"]["operation_id"] != request["child"]["operation_id"]
end
