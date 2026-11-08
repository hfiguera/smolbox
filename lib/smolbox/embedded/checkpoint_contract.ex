defmodule SmolBox.Embedded.CheckpointContract do
  @moduledoc false
  alias SmolBox.Backend.Features
  alias SmolBox.Checkpoint
  alias SmolBox.Embedded.Shape

  # Only operator configuration conveys host paths. A request uses artifact/1.
  # This ceiling matches the shared engine's separate checkpoint input budget.
  @artifact_bytes 64 * 1024 * 1024 * 1024

  def marker?(value, major) when is_map(value),
    do:
      not Map.has_key?(value, "checkpointable") or
        (major == 2 and value["checkpointable"] == true and mode?(value))

  def marker?(_value, _major), do: false

  defp mode?(value) do
    features = value["features"]

    not Map.has_key?(value, "volume_mounts") and value["source"]["kind"] != "oci" and
      (features == nil or
         (is_map(features) and is_map(features["network"]) and
            features["network"]["enabled"] == false and
            features["ports"] == [] and features["workload"] == nil))
  end

  def attach(value, spec),
    do:
      if(Map.get(spec, :checkpointable, false),
        do: Map.put(value, "checkpointable", true),
        else: value
      )

  def matches?(value, spec, retained),
    do:
      if(retained == nil,
        do: Map.get(value, "checkpointable", false) == Map.get(spec, :checkpointable, false),
        else: marker?(value, 2)
      )

  def opt_in_approved?(config, value),
    do:
      marker?(value, 2) and
        (not Map.has_key?(value, "checkpointable") or Features.supports?(config, :checkpoints))

  def source?(source) do
    Shape.keys?(source, ~w(kind id sha256 architecture)) and source["kind"] == "checkpoint" and
      Shape.id?(source["id"]) and Shape.hex?(source["sha256"], 64) and
      source["architecture"] in ~w(x86_64 aarch64)
  end

  def creation?(creation) do
    marker?(creation, 2) and
      Shape.keys?(
        Map.delete(creation, "checkpointable"),
        ~w(name owner_token incarnation source resources labels)
      ) and
      Shape.id?(creation["name"]) and Shape.hex?(creation["owner_token"], 64) and
      Shape.hex?(creation["incarnation"], 32) and source?(creation["source"]) and
      Shape.resources?(creation["resources"]) and creation["labels"] == %{}
  end

  def approved?(config, request) do
    Enum.any?(approvals(config), fn approval ->
      approval["source"] == request["source"] and approval["resources"] == request["resources"]
    end)
  end

  def approvals(config) do
    Enum.map(config.checkpoints, fn checkpoint ->
      profile = checkpoint.profile

      %{
        "source" => Checkpoint.artifact(checkpoint),
        "path" => checkpoint.path,
        "max_bytes" => @artifact_bytes,
        "sdk_version" => checkpoint.runtime_version,
        "host_platform" => host_platform(checkpoint),
        "resources" => %{
          "cpus" => profile.cpus,
          "memory_mib" => profile.memory_mb,
          "storage_gib" => profile.storage_gb,
          "overlay_gib" => profile.overlay_gb
        }
      }
    end)
  end

  defp host_platform(%{platform: :linux, architecture: "x86_64"}), do: "linux/amd64"
  defp host_platform(%{platform: :macos, architecture: "aarch64"}), do: "darwin/arm64"
end
