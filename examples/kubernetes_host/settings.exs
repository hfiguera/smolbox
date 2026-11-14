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

{:ok, node} =
  LabNodeEvidence.new(
    ssh_host: settings["ssh_host"],
    inspector_sha256: settings["inspector_sha256"],
    history_sha256: settings["history_sha256"]
  )

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
        credential_provider: {:token_file, settings["token_file"]},
        sources: [source],
        profiles: [profile],
        node_evidence: {LabNodeEvidence, node},
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
