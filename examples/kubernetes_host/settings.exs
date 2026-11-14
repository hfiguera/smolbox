# Trusted host configuration for scripts/kubernetes/backend-smoke.exs.
# JSON contains administrator approvals, never values from a submitted execution.
alias SmolBox.ArtifactStore.Directory
alias SmolBox.Kubernetes.{Config, LabController, LabNodeEvidence}
alias SmolBox.{Profile, Source}

path = System.fetch_env!("SMOLBOX_KUBERNETES_ENROLLMENT")
settings = path |> File.read!() |> Jason.decode!()

{:ok, source} =
  Source.oci(id: "python-preview", reference: settings["image"], architecture: "x86_64")

{:ok, profile} =
  Profile.new("kubernetes-preview",
    cpus: 2,
    memory_mb: 1024,
    storage_gb: 20,
    overlay_gb: 10,
    host_overhead_mb: 512,
    preparation_ms: 300_000
  )

node_evidence =
  case Map.get(settings, "node_provider", "lab") do
    "lab" ->
      {:ok, node} =
        LabNodeEvidence.new(
          ssh_host: settings["ssh_host"],
          inspector_sha256: settings["inspector_sha256"],
          history_sha256: settings["history_sha256"]
        )

      {LabNodeEvidence, node}

    "node_authority" ->
      provider = SmolBox.Kubernetes.NodeAuthority

      unless Code.ensure_loaded?(provider) and function_exported?(provider, :new, 1),
        do: raise("this SDK does not support the configured node authority provider")

      approval = Map.fetch!(settings, "node_authority")

      fields =
        ~w(ssh_host ssh_port ssh_user identity_file known_hosts_file authority_generation verifier_manifest_sha256)a

      options = Enum.map(fields, &{&1, Map.fetch!(approval, Atom.to_string(&1))})
      {:ok, node} = apply(provider, :new, [options])
      {provider, node}

    _ ->
      raise "unknown node evidence provider"
  end

{:ok, controller} =
  LabController.new(
    directory: settings["controller_directory"],
    python_executable: settings["python_executable"]
  )

fields =
  ~w(id api_server ca_file cluster_id cluster_anchor_uid namespace namespace_uid node_name node_uid node_boot_id runtime_class runtime_class_uid runtime_policy_digest runtime_identity)a

options = Enum.map(fields, &{&1, Map.fetch!(settings, Atom.to_string(&1))})

{:ok, target} =
  Config.new(
    options ++
      [
        runtime_version: Map.get(settings, "runtime_version", "1.35.1"),
        credential_provider: {:token_file, settings["token_file"]},
        sources: [source],
        profiles: [profile],
        node_evidence: node_evidence,
        controller_guard: controller
      ]
  )

{:ok, _} = Directory.new(settings["artifact_root"])
{:ok, memory} = SmolBox.Store.Memory.start_link()

%{
  target: target,
  mode: :ephemeral,
  store: {SmolBox.Store.Memory, memory},
  artifact_root: settings["artifact_root"],
  report_root: settings["report_root"],
  fingerprint_key: File.read!(settings["fingerprint_key_file"])
}
