# Manual Mac/controller checks against the actual enrolled idle node.
# Connection fields, approvals and all paths are trusted administrator inputs.
alias SmolBox.Backend.Budget
alias SmolBox.Kubernetes.{Binding, NodeAuthority}

settings = System.fetch_env!("SMOLBOX_NODE_AUTHORITY_ACCESS") |> File.read!() |> Jason.decode!()
raw = settings["binding"]

fields =
  ~w(target_id cluster_id cluster_anchor_uid namespace namespace_uid node_name node_uid node_boot_id runtime_class runtime_class_uid runtime_policy_digest runtime_identity)a

{:ok, binding} = Binding.new(Enum.map(fields, &{&1, Map.fetch!(raw, Atom.to_string(&1))}))

connection =
  ~w(ssh_host ssh_port ssh_user identity_file known_hosts_file authority_generation verifier_manifest_sha256)a

{:ok, context} =
  NodeAuthority.new(Enum.map(connection, &{&1, Map.fetch!(settings, Atom.to_string(&1))}))

budget = %Budget{timeout_ms: 5000, max_request_bytes: 65_544, max_response_bytes: 65_544}

{:ok, wrong_binding} =
  Binding.new(
    Enum.map(fields, &{&1, Map.fetch!(raw, Atom.to_string(&1))})
    |> Keyword.put(:node_uid, "different-node")
  )

candidates = [
  {"approved_positive_idle", :ok, binding, context},
  {"wrong_host_key_denied", :transport, binding,
   %{context | known_hosts_file: settings["wrong_known_hosts_file"]}},
  {"wrong_private_key_denied", :transport, binding,
   %{context | identity_file: settings["wrong_identity_file"]}},
  {"missing_private_key_denied", :transport, binding,
   %{context | identity_file: settings["missing_identity_file"]}},
  {"wrong_endpoint_denied", :transport, binding,
   %{context | ssh_port: settings["wrong_ssh_port"]}},
  {"wrong_manifest_denied", :identity_conflict, binding,
   %{context | verifier_manifest_sha256: String.duplicate("f", 64)}},
  {"wrong_generation_denied", :identity_conflict, binding,
   %{context | authority_generation: String.duplicate("f", 64)}},
  {"wrong_node_binding_denied", :identity_conflict, wrong_binding, context}
]

controls =
  for {name, expected, target, candidate} <- candidates, into: %{} do
    started = System.monotonic_time(:millisecond)

    passed =
      case NodeAuthority.check(target, budget, candidate) do
        {:ok, %{complete_history: true, idle: true, observer_epoch: epoch}}
        when expected == :ok ->
          epoch == context.authority_generation

        {:error,
         %SmolBox.Error{category: ^expected, exit_code: nil, evidence: :not_dispatched} = error} ->
          SmolBox.Error.valid?(error) and
            not String.contains?(inspect(error), candidate.identity_file)

        _ ->
          false
      end

    {name, %{passed: passed, elapsed_ms: System.monotonic_time(:millisecond) - started}}
  end

report = %{
  version: 1,
  scope: "real_enrolled_client_access_only",
  authority_generation: context.authority_generation,
  verifier_manifest_sha256: context.verifier_manifest_sha256,
  binding_generation: binding.generation,
  controls: controls,
  all_controls_passed: Enum.all?(controls, fn {_, value} -> value.passed end),
  no_workload_execution_performed: true
}

File.write!(settings["report"], Jason.encode!(report, pretty: true) <> "\n", [:exclusive])
IO.puts("Enrolled client controls passed: #{report.all_controls_passed}")
true = report.all_controls_passed
