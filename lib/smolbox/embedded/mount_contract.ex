defmodule SmolBox.Embedded.MountContract do
  @moduledoc false
  alias SmolBox.Backend.Features
  alias SmolBox.Embedded.{CreationFeatures, Shape, VolumeContract}
  alias SmolBox.{ExecutionSpec, Mount, Validation}

  def approved?(create, config) do
    case Map.fetch(create, "volume_mounts") do
      :error ->
        true

      {:ok, mounts} ->
        approved_mounts?(mounts, config)
    end
  end

  defp approved_mounts?(mounts, %{volume_policy: %{id: id, root: root}} = config),
    do:
      config.platform == :linux and Features.supports?(config, :volumes) and
        bound?(mounts, %{target_id: config.id, generation: config.domain_generation}) and
        Enum.all?(mounts, &(&1["proof"]["backing"]["policy"] == %{"id" => id, "root" => root}))

  defp approved_mounts?(_, _), do: false

  def matches_spec?(create, %ExecutionSpec{scope: scope}, {scope, id}),
    do:
      Validation.identifier?(id) and
        (not Map.has_key?(create, "volume_mounts") or valid?(create["volume_mounts"]))

  def matches_spec?(create, spec, nil) do
    refs = Map.get(spec, :volumes, [])
    mounts = Map.get(create, "volume_mounts", [])

    length(refs) == length(mounts) and
      Enum.all?(Enum.zip(refs, mounts), fn {ref, mount} ->
        ref.target == mount["target"] and ref.readonly == mount["readonly"]
      end)
  end

  def matches_spec?(_, _, _), do: false

  def record_matches?(%{native_mounts: mounts, backend_assignment: %{creation: create}}),
    do:
      Map.get(create, "volume_mounts", []) ==
        Enum.map(mounts, &wire_attachment/1)

  def record_matches?(%{managed_machine: {_scope, _id}}), do: true

  def record_matches?(%{backend_assignment: %{creation: create}}),
    do: not Map.has_key?(create, "volume_mounts")

  def attach(create, []), do: create

  def attach(create, attachments),
    do:
      Map.put(
        create,
        "volume_mounts",
        Enum.map(attachments, &wire_attachment/1)
      )

  def attachments_match?(attachments, spec) do
    refs = Map.get(spec, :volumes, [])

    Validation.list?(attachments, 8) and length(refs) == length(attachments) and
      Enum.all?(Enum.zip(refs, attachments), fn {ref, attachment} ->
        attachment.volume_key == {spec.scope, ref.volume_id} and
          attachment.target == ref.target and attachment.readonly == ref.readonly
      end)
  end

  defp wire_attachment(attachment),
    do:
      Map.new(~w(proof target readonly)a, fn key ->
        {Atom.to_string(key), Map.fetch!(attachment, key)}
      end)

  def valid?(mounts),
    do:
      Validation.list?(mounts, 8) and mounts != [] and Enum.all?(mounts, &mount?/1) and
        mounts == Enum.sort_by(mounts, & &1["target"]) and unique?(mounts) and
        same_policy?(mounts) and nonoverlapping?(mounts)

  def bound?(mounts, binding),
    do:
      valid?(mounts) and
        Enum.all?(mounts, fn mount ->
          mount["proof"]["backing"]["target_id"] == binding.target_id and
            mount["proof"]["backing"]["domain_generation"] == binding.generation
        end)

  def creation_keys?(creation, keys, major) when is_map(creation) do
    (not Map.has_key?(creation, "volume_mounts") or
       (major == 2 and valid?(creation["volume_mounts"]))) and
      feature_keys?(Map.delete(creation, "volume_mounts"), keys, major)
  end

  def creation_keys?(_, _, _), do: false

  def paths(create),
    do:
      Enum.map(Map.get(create, "volume_mounts", []), fn mount ->
        %Mount{
          source:
            mount["proof"]["backing"]["policy"]["root"] <>
              "/" <>
              mount["proof"]["backing"]["intent"]["worker_volume_id"],
          target: mount["target"],
          readonly: mount["readonly"]
        }
      end)

  defp mount?(mount),
    do:
      Shape.keys?(mount, ~w(proof target readonly)) and Mount.target?(mount["target"]) and
        is_boolean(mount["readonly"]) and
        VolumeContract.result?(%{
          "result" => "volume",
          "volume" => %{"status" => "provisioned", "proof" => mount["proof"]}
        })

  defp unique?(mounts),
    do:
      length(Enum.uniq_by(mounts, & &1["proof"]["backing"]["intent"]["worker_volume_id"])) ==
        length(mounts)

  defp same_policy?([first | _] = mounts),
    do:
      Enum.all?(mounts, fn mount ->
        mount["proof"]["backing"]["policy"] == first["proof"]["backing"]["policy"] and
          mount["proof"]["account"] == first["proof"]["account"]
      end)

  defp nonoverlapping?(mounts),
    do:
      Enum.all?(mounts, fn mount ->
        Enum.count(mounts, fn other ->
          mount["target"] == other["target"] or
            String.starts_with?(other["target"], mount["target"] <> "/")
        end) == 1
      end)

  defp feature_keys?(value, keys, major),
    do:
      Shape.keys?(value, keys) or
        (major == 2 and Shape.keys?(value, keys ++ ["features"]) and
           CreationFeatures.valid?(value["features"]))
end
