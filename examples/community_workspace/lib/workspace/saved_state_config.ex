defmodule Workspace.SavedStateConfig do
  @moduledoc "Explicit approvals for the separate offline saved state workspace."
  alias SmolBox.{BranchPolicy, Checkpoint, CheckpointPolicy, Profile}

  def build(%{"saved_state" => s, "platform" => "linux", "architecture" => arch} = settings, root) do
    with true <- settings["runtime_version"] == "1.19.0",
         {:ok, profile} <-
           Profile.new("workspace-saved-state-v1",
             cpus: 1,
             memory_mb: 256,
             storage_gb: 1,
             overlay_gb: 1,
             host_overhead_mb: 768,
             preparation_ms: 120_000,
             execution_ms: 120_000
           ),
         {:ok, seed} <-
           Checkpoint.new(
             id: "workspace-idle-seed",
             path: s["path"],
             sha256: s["sha256"],
             profile: profile,
             platform: :linux,
             architecture: arch,
             runtime_version: "1.19.0"
           ),
         {:ok, capture} <-
           CheckpointPolicy.new(
             id: "workspace-captures",
             root: Path.join(root, "captures"),
             max_bytes: 1_073_741_824,
             resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 16}
           ),
         {:ok, branch} <-
           BranchPolicy.new(
             id: "workspace-branches",
             resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 8}
           ) do
      {:ok, %{profile: profile, seed: seed, capture_policy: capture, branch_policy: branch}}
    else
      _ -> {:error, :saved_state_configuration_invalid}
    end
  end

  def build(%{"saved_state" => _}, _), do: {:error, :saved_state_configuration_invalid}
  def build(_, _), do: {:ok, nil}

  def worker_options(nil, profile) do
    [
      profiles: [profile],
      allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768},
      capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 4}
    ]
  end

  def worker_options(lab, profile) do
    [
      profiles: [profile, lab.profile],
      checkpoints: [lab.seed],
      checkpoint_policies: [lab.capture_policy],
      branch_policies: [lab.branch_policy],
      allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768},
      capacity: %{slots: 4, cpus: 4, memory_mb: 4096, disk_gb: 32}
    ]
  end
end
