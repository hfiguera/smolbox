defmodule SmolBox.Embedded.SDKIdentity do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @features ~w(lifecycle foreground_exec extended_exec files extended_files material_proofs
               observability networking ports workloads compact_creation job_resources buffered_exec remote_sources images background_exec
               logs streaming_exec terminals volumes disk_growth checkpoints exports branches)

  # This is the implemented package contract, not all APIs present in the SDK.
  # Launch and Hello must both bind it to the exact locally approved package.
  @implemented %{
    "lifecycle" => 1,
    "foreground_exec" => 1,
    "extended_exec" => 1,
    "files" => 1,
    "extended_files" => 1,
    "material_proofs" => 2,
    "observability" => 1,
    "networking" => 1,
    "ports" => 1,
    "workloads" => 1,
    "compact_creation" => 1,
    "job_resources" => 1,
    "buffered_exec" => 1,
    "background_exec" => 1,
    "logs" => 1,
    "streaming_exec" => 1,
    "terminals" => 1
  }

  def implemented(version, revision),
    do: %{
      "sdk_version" => version,
      "source_revision" => revision,
      "feature_versions" => @implemented
    }

  def valid?(sdk),
    do:
      Shape.keys?(sdk, ~w(sdk_version source_revision feature_versions)) and
        Shape.text?(sdk["sdk_version"], 64, false) and Shape.hex?(sdk["source_revision"], 40) and
        features?(sdk["feature_versions"])

  def approved?(sdk, version, revision) do
    valid?(sdk) and sdk["sdk_version"] == version and sdk["source_revision"] == revision and
      Map.take(
        sdk["feature_versions"],
        ~w(lifecycle foreground_exec extended_exec files extended_files material_proofs)
      ) ==
        Map.take(
          @implemented,
          ~w(lifecycle foreground_exec extended_exec files extended_files material_proofs)
        ) and
      Enum.all?(sdk["feature_versions"], fn {name, value} -> @implemented[name] == value end)
  end

  defp features?(features),
    do:
      is_map(features) and map_size(features) <= 32 and features["material_proofs"] == 2 and
        dependencies?(features) and
        Enum.all?(features, fn {name, version} ->
          name in @features and Validation.integer?(version, 1, 2) and
            version == if(name == "material_proofs", do: 2, else: 1)
        end)

  defp dependencies?(features),
    do:
      Enum.all?(
        [
          {"buffered_exec", "job_resources"},
          {"background_exec", "buffered_exec"},
          {"logs", "buffered_exec"},
          {"streaming_exec", "buffered_exec"},
          {"terminals", "buffered_exec"},
          {"disk_growth", "job_resources"},
          {"images", "job_resources"},
          {"remote_sources", "job_resources"},
          {"remote_sources", "buffered_exec"},
          {"remote_sources", "compact_creation"}
        ],
        fn {feature, required} -> features[feature] != 1 or features[required] == 1 end
      )
end
