# Trusted manual qualification configuration, never an execution input or default.
alias SmolBox.Kubernetes.{Config, NodeAuthority}
alias SmolBox.NodeAuthorityCampaign.Store, as: AuditStore

Code.require_file(Path.join(__DIR__, "campaign_store.exs"))
repository = Path.expand("../../..", __DIR__)
directory = System.fetch_env!("SMOLBOX_NODE_AUTHORITY_QUALIFICATION")

case System.argv() do
  [_, "cancel", "authority-" <> name] when name in ["memory-cancel", "postgres-cancel"] ->
    System.put_env(
      "SMOLBOX_KUBERNETES_DISPATCH_TRACE",
      Path.join(directory, name <> "-trace.jsonl")
    )

  _ ->
    :ok
end

{settings, _} = Code.eval_file(Path.join(repository, "examples/kubernetes_host/settings.exs"))
{NodeAuthority, node} = settings.target.node_evidence

profiles = [
  hd(settings.target.profiles),
  %{hd(settings.target.profiles) | id: "kubernetes-preview-cap-1", max_output_bytes: 1},
  %{hd(settings.target.profiles) | id: "kubernetes-preview-cap-4096", max_output_bytes: 4096},
  %{hd(settings.target.profiles) | id: "kubernetes-preview-collection", collection_ms: 120_000}
]

selected = System.get_env("SMOLBOX_AUTHORITY_PROFILE", "kubernetes-preview")
profile = Enum.find(profiles, &(&1.id == selected)) || raise("unknown qualification profile")
profiles = [profile | Enum.reject(profiles, &(&1.id == selected))]

node =
  case System.get_env("SMOLBOX_AUTHORITY_BAD_APPROVAL") do
    nil -> node
    "manifest" -> %{node | verifier_manifest_sha256: String.duplicate("f", 64)}
    "generation" -> %{node | authority_generation: String.duplicate("f", 64)}
    _ -> raise "unknown qualification approval control"
  end

node = %{
  node
  | ssh_executable: System.get_env("SMOLBOX_AUTHORITY_FAULT_SSH", node.ssh_executable)
}

target = %{settings.target | profiles: profiles, node_evidence: {NodeAuthority, node}}
:ok = Config.validate(target)

{mode, delegate} =
  case System.get_env("SMOLBOX_AUTHORITY_STORE", "memory") do
    "memory" ->
      {:ephemeral, settings.store}

    "postgresql" ->
      {SmolBox.Store.Memory, unused} = settings.store
      GenServer.stop(unused)
      adapter = SmolBox.DurableHost.Store
      repo = SmolBox.DurableHost.Repo
      true = Code.ensure_loaded?(adapter) and Process.whereis(repo) != nil

      {:ok, store} =
        adapter.new(
          repo,
          System.get_env("SMOLBOX_AUTHORITY_PARTITION", "node-authority-live-v1-20261114"),
          File.read!(Path.join(directory, "encryption-key"))
        )

      {:durable, {adapter, store}}

    _ ->
      raise "unknown qualification store; no fallback"
  end

%{
  settings
  | target: target,
    mode: mode,
    store: {AuditStore, %{delegate: delegate, directory: settings.report_root}}
}
