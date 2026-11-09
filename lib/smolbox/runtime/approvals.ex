defmodule SmolBox.Runtime.Approvals do
  @moduledoc false
  alias SmolBox.{Checkpoint, Profile, Validation}

  @artifact_versions ~w(1.19.0 1.20.2 1.22.0 1.34.0)

  def sources?(entries, sdk_version, architecture) do
    Validation.list?(entries, 32) and
      Enum.all?(entries, fn source ->
        SmolBox.Source.validate(source) == :ok and source.kind in [:registry, :oci] and
          source.architecture == architecture and sdk_version in @artifact_versions
      end) and unique?(entries, & &1.id)
  end

  def checkpoints?(entries, sdk_version, platform, architecture, profiles) do
    Validation.list?(entries, 32) and
      Enum.all?(entries, fn checkpoint ->
        Checkpoint.validate(checkpoint) == :ok and checkpoint.platform == platform and
          checkpoint.architecture == architecture and checkpoint.runtime_version == sdk_version and
          checkpoint.profile in profiles
      end) and unique?(entries, & &1.id)
  end

  def export_destinations?(entries, sdk_version),
    do: policies?(entries, sdk_version, SmolBox.ExportDestination)

  def checkpoint_policies?(entries, sdk_version),
    do: policies?(entries, sdk_version, SmolBox.CheckpointPolicy)

  def branch_policies?(entries, sdk_version),
    do: policies?(entries, sdk_version, SmolBox.BranchPolicy)

  def volume_policy?(nil, _sdk_version, _platform), do: true

  def volume_policy?(policy, sdk_version, platform),
    do:
      sdk_version in ~w(1.20.2 1.22.0 1.34.0) and platform == :linux and
        SmolBox.VolumePolicy.valid?(policy)

  def profiles?(profiles),
    do:
      Validation.list?(profiles, 32) and profiles != [] and
        Enum.all?(profiles, &(Profile.validate(&1) == :ok)) and unique?(profiles, & &1.id)

  def capacity?(capacity),
    do:
      is_map(capacity) and Enum.sort(Map.keys(capacity)) == [:cpus, :disk_gb, :memory_mb, :slots] and
        Enum.all?(Map.values(capacity), &Validation.integer?(&1, 1, 1_048_576))

  def allocation_floor?(
        %{storage_gb: storage, overlay_gb: overlay, host_overhead_mb: memory} = floor
      ),
      do:
        map_size(floor) == 3 and Validation.integer?(storage, 1, 64) and
          Validation.integer?(overlay, 1, 64) and Validation.integer?(memory, 128, 16_384)

  def allocation_floor?(_floor), do: false

  def allocation_fits?(floor, profile),
    do: Enum.all?(floor, fn {field, minimum} -> Map.fetch!(profile, field) >= minimum end)

  def unique?(entries, function),
    do: MapSet.size(MapSet.new(entries, function)) == length(entries)

  defp policies?(entries, sdk_version, module),
    do:
      Validation.list?(entries, 32) and
        Enum.all?(entries, &(sdk_version in @artifact_versions and module.validate(&1) == :ok)) and
        unique?(entries, & &1.id)
end
