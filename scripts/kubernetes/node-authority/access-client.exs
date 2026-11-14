# Manual Mac/client-host check against the pre-enrollment access fixture only.
# Settings and key files are administrator inputs, never execution payloads.
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

budget = %Budget{timeout_ms: 3000, max_request_bytes: 65_544, max_response_bytes: 65_544}

controls =
  for {name, expected, candidate} <- [
        {"authenticated_pre_enrollment_rejection", :identity_conflict, context},
        {"wrong_host_key_denied", :transport,
         %{context | known_hosts_file: settings["wrong_known_hosts_file"]}},
        {"wrong_private_key_denied", :transport,
         %{context | identity_file: settings["wrong_identity_file"]}},
        {"missing_private_key_denied", :transport,
         %{context | identity_file: settings["missing_identity_file"]}}
      ],
      into: %{} do
    valid =
      case NodeAuthority.check(binding, budget, candidate) do
        {:error,
         %SmolBox.Error{category: ^expected, exit_code: nil, evidence: :not_dispatched} = error} ->
          SmolBox.Error.valid?(error) and
            not String.contains?(inspect(error), candidate.identity_file)

        _ ->
          false
      end

    {name, valid}
  end

{ssh, 0} = System.cmd("/usr/bin/ssh", ["-V"], stderr_to_stdout: true)

report = %{
  version: 1,
  scope: "pre_enrollment_client_access_only",
  client_platform: :os.type(),
  ssh_version: String.trim(ssh),
  controls: controls,
  all_controls_passed: Enum.all?(controls, &elem(&1, 1)),
  no_node_enrollment_or_workload_evidence: true
}

# Convert the OS tuple explicitly; no operational context is serialized.
report = %{
  report
  | client_platform: report.client_platform |> Tuple.to_list() |> Enum.map(&Atom.to_string/1)
}

File.write!(settings["report"], Jason.encode!(report, pretty: true) <> "\n")

if not report.all_controls_passed,
  do: raise("node authority access client controls failed; inspect redacted report")

IO.puts("Standalone SDK authenticated rejection and host/key negative controls passed")
