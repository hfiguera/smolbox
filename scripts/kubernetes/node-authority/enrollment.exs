# Manual pure SDK binding construction from the fresh guest's administrator
# metadata. This performs no SSH/API call and cannot install or enable authority.
alias SmolBox.Kubernetes.{Binding, Enrollment}
alias SmolBox.Kubernetes.NodeAuthority.JSON

directory = System.fetch_env!("SMOLBOX_NODE_AUTHORITY_QUALIFICATION")
metadata = directory |> Path.join("metadata.json") |> File.read!() |> Jason.decode!()

{:ok, binding} =
  Binding.new(
    target_id: System.get_env("SMOLBOX_AUTHORITY_TARGET_ID", "node-authority-v1"),
    cluster_id: System.get_env("SMOLBOX_AUTHORITY_CLUSTER_ID", "node-authority-qualification-v1"),
    cluster_anchor_uid: metadata["cluster_anchor"]["metadata"]["uid"],
    namespace: "smolbox-preview",
    namespace_uid: metadata["namespace"]["metadata"]["uid"],
    node_name: "smolbox-k3s",
    node_uid: metadata["node"]["metadata"]["uid"],
    node_boot_id: metadata["node_boot_id"],
    runtime_class: "smolbox-preview",
    runtime_class_uid: metadata["runtime_class"]["metadata"]["uid"],
    runtime_policy_digest:
      Enrollment.policy_digest(metadata["runtime_class"], metadata["network_policy"]),
    runtime_identity: metadata["runtime_identity"]
  )

wire = binding |> Map.from_struct() |> Jason.encode!() |> Jason.decode!()
{:ok, bytes} = JSON.encode(wire)
File.write!(Path.join(directory, "binding.json"), bytes, [:exclusive])
IO.puts("Saved SDK binding #{binding.generation}; no authority enrolled or enabled")
