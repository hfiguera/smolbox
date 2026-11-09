defmodule SmolBox.Embedded.BranchOrigin do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, BranchRequest, Shape}
  alias SmolBox.Validation

  @sdk_revisions ~w(9f446ae00219148ca4a703914f44a8e2fab11655 d77eaf1c6eeff16bc8c258613746033e9bf567ca)

  def valid?(binding, child),
    do:
      BranchCanonical.keys?(binding, :binding) and Shape.receipt?(child, 2) and
        intent?(binding["intent"]) and
        Shape.hex?(binding["generation"], 8) and Validation.digest?(binding["raw_child_sha256"]) and
        child_matches?(binding["intent"], child)

  def intent?(intent) do
    BranchCanonical.keys?(intent, :intent) and Shape.receipt?(intent["source"], 2) and
      intent["source"]["material"]["revision"] < 1024 and
      BranchRequest.child?(intent["child"], intent["source"]) and
      BranchRequest.approval?(intent["approval"]) and Shape.hex?(intent["epoch"], 32) and
      pid?(intent["source_pid"]) and plan?(intent["plan"], intent["approval"]) and
      Enum.any?(@sdk_revisions, &(intent["request_sha256"] == admission_digest(intent, &1)))
  end

  defp child_matches?(intent, child),
    do:
      Enum.all?(~w(target_id domain_generation), &(child[&1] == intent["source"][&1])) and
        Enum.all?(~w(name owner_token incarnation), &(child[&1] == intent["child"][&1]))

  defp plan?(plan, approval) do
    BranchCanonical.keys?(plan, :plan) and BranchRequest.resources?(plan["ordinary_child"]) and
      Validation.integer?(plan["minimum_extra_memory_mb"], 1, 18_446_744_073_709_551_615) and
      Validation.integer?(plan["minimum_extra_disk_gb"], 1, 18_446_744_073_709_551_615) and
      BranchCanonical.keys?(plan["total_additional"], :resources) and
      Enum.all?(~w(slots cpus memory_mb disk_gb), fn key ->
        Validation.integer?(plan["total_additional"][key], 1, 18_446_744_073_709_551_615)
      end) and
      child_resources?(plan["ordinary_child"], approval) and extra?(plan, approval)
  end

  defp child_resources?(child, approval),
    do:
      child["slots"] == 1 and Validation.integer?(child["cpus"], 1, 16) and
        Validation.integer?(child["memory_mb"] - approval["host_overhead_mb"], 64, 65_536) and
        Validation.integer?(child["disk_gb"], 2, 2048)

  defp extra?(plan, approval) do
    child = plan["ordinary_child"]
    extra = approval["resources"]
    memory = child["memory_mb"] - approval["host_overhead_mb"]
    disks = child["disk_gb"] * 2 + div(memory + 1023, 1024)

    plan["minimum_extra_memory_mb"] == child["memory_mb"] and
      plan["minimum_extra_disk_gb"] == disks and extra["memory_mb"] >= child["memory_mb"] and
      extra["disk_gb"] >= disks and
      Enum.all?(~w(slots cpus memory_mb disk_gb), fn key ->
        plan["total_additional"][key] == child[key] + extra[key]
      end)
  end

  defp admission_digest(intent, revision),
    do:
      BranchCanonical.digest([
        "smolbox-initial-branch-admission-v1",
        revision,
        "shared-materialized-ram",
        BranchCanonical.ordered(intent["source"], :receipt),
        BranchCanonical.ordered(intent["child"], :child),
        BranchCanonical.ordered(intent["approval"], :approval),
        BranchCanonical.ordered(intent["plan"], :plan),
        intent["source_pid"],
        intent["epoch"]
      ])

  defp pid?([pid, birth]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(birth, 1, 18_446_744_073_709_551_615)

  defp pid?(_), do: false
end
