defmodule SmolBox.NodeAuthorityCampaign.Recovery do
  @moduledoc false
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Command, Execution, ExecutionSpec, Files, Runtime, Source}
  alias SmolBox.Kubernetes.{CleanupProof, Config}

  defmodule HeldArtifacts do
    @moduledoc false
    @behaviour SmolBox.ArtifactStore
    @impl true
    def read(context, scope, reference, max),
      do: Directory.read(context.store, scope, reference, max)

    @impl true
    def put(context, key, destination, bytes, digest) do
      File.write!(
        Path.join(context.gate, "publisher.json"),
        Jason.encode!(%{
          key: Tuple.to_list(key),
          size: byte_size(bytes),
          sha256: digest,
          owner_pid: System.pid()
        }),
        [:exclusive, :sync]
      )

      send(context.owner, :publishing)
      wait(context.gate, System.monotonic_time(:millisecond) + 90_000)
      Directory.put(context.store, key, destination, bytes, digest)
    end

    defp wait(gate, deadline) do
      true = System.monotonic_time(:millisecond) < deadline

      if File.exists?(Path.join(gate, "publish.allow")),
        do: :ok,
        else:
          (
            Process.sleep(100)
            wait(gate, deadline)
          )
    end
  end

  def main([action, id])
      when action in ["hold", "resume", "resume-held", "standby", "inspect", "probe"] do
    root = System.fetch_env!("SMOLBOX_NODE_AUTHORITY_QUALIFICATION")
    {settings, _} = Code.eval_file(Path.join(__DIR__, "campaign_settings.exs"))
    key = {"kubernetes-smoke", id}
    gate = Path.join(root, id)
    {:ok, artifacts} = Directory.new(settings.artifact_root)
    dispatch(action, settings, artifacts, root, gate, key)
  end

  defp dispatch("probe", settings, _, root, _, _) do
    {provider, context} = settings.target.node_evidence

    budget = %SmolBox.Backend.Budget{
      timeout_ms: 20_000,
      max_request_bytes: 65_544,
      max_response_bytes: 65_544
    }

    report(root, "probe-start.json", %{
      pid: System.pid(),
      timeout_ms: budget.timeout_ms,
      started_at_ms: System.system_time(:millisecond)
    })

    outcome = provider.check(Config.binding(settings.target), budget, context)

    report(root, "probe-result.json", %{
      returned: match?({:ok, _}, outcome),
      ended_at_ms: System.system_time(:millisecond)
    })
  end

  defp dispatch("inspect", settings, _, root, _, key) do
    {:ok, record} = fetch(settings, key)

    report(
      root,
      elem(key, 1) <> "-inspection-" <> System.pid() <> ".json",
      summary(settings, record)
    )
  end

  defp dispatch("standby", settings, artifacts, root, _, key) do
    Process.flag(:trap_exit, true)
    outcome = Runtime.start_link(options(settings, {Directory, artifacts}))

    denied =
      case outcome do
        {:ok, runtime} ->
          Process.sleep(1000)
          {:ok, reports} = GenServer.call(Runtime.coordinator(runtime), :workers)
          blocked = Enum.all?(reports, &(&1.status != :ready))
          Supervisor.stop(runtime, :normal, 5000)
          blocked

        {:error, _} ->
          true
      end

    {:ok, record} = fetch(settings, key)

    report(root, elem(key, 1) <> "-standby.json", %{
      denied: denied,
      original_record: summary(settings, record)
    })

    true = denied
  end

  defp dispatch(action, settings, artifacts, root, gate, key)
       when action in ["hold", "resume", "resume-held"] do
    publication_gate =
      if action == "resume-held", do: Path.join(gate, "recovery-publication"), else: gate

    held? = action in ["hold", "resume-held"]
    if held?, do: File.mkdir!(publication_gate)

    artifact_store =
      if held?,
        do: {HeldArtifacts, %{store: artifacts, owner: self(), gate: publication_gate}},
        else: {Directory, artifacts}

    {:ok, runtime} = Runtime.start_link(options(settings, artifact_store))

    try do
      if action == "hold" do
        {:ok, ^key} = SmolBox.submit(runtime, spec(settings.target, artifacts, elem(key, 1)))
      end

      if held? do
        publication_boundary(action, runtime, settings, key, publication_gate)
      end

      record = wait_clean(settings, key, System.monotonic_time(:millisecond) + 300_000)
      true = record.result.exit_code == 7 and record.collection == :complete
      true = CleanupProof.releasable?(record.backend_cleanup, record.backend_receipt)
      {:ok, bytes} = Directory.read_output(artifacts, key, "binary-output", 4352)
      true = Files.sha256(bytes) == Files.sha256(:binary.copy(<<17, 128, 255, 0>>, 1088))
      report(root, elem(key, 1) <> "-recovered.json", summary(settings, record))
      IO.puts("Recovered original exit/artifact, v3 proof and zero usage")
    after
      Supervisor.stop(runtime, :normal, 5000)
    end
  end

  defp publication_boundary(action, runtime, settings, key, gate) do
    receive do
      :publishing -> :ok
    after
      90_000 -> raise "publication boundary not reached"
    end

    {:ok, record} = fetch(settings, key)
    true = record.state == :collecting and record.result.exit_code == 7
    queued = if action == "hold", do: queued_cancellation(runtime, settings, record)

    report(
      gate,
      "boundary.json",
      Map.merge(summary(settings, record), %{
        owner_pid: System.pid(),
        queued: if(queued, do: Tuple.to_list(queued))
      })
    )
  end

  defp queued_cancellation(runtime, settings, record) do
    {:ok, queued} =
      SmolBox.submit(runtime, %{
        record.spec
        | id: record.spec.id <> "-queued",
          inputs: [],
          outputs: []
      })

    Process.sleep(1000)
    {:ok, waiting} = fetch(settings, queued)
    true = waiting.state == :accepted and waiting.reservation == nil
    {:ok, _} = SmolBox.cancel(runtime, elem(queued, 0), elem(queued, 1))
    queued
  end

  defp options(settings, artifacts),
    do: [
      name: __MODULE__,
      namespace: "kubepublic",
      mode: settings.mode,
      store: settings.store,
      artifact_store: artifacts,
      workers: [settings.target],
      fingerprint_key: settings.fingerprint_key,
      max_active: 2,
      poll_ms: 250,
      lease_ms: 5000
    ]

  defp spec(target, artifacts, id) do
    bytes = :binary.copy(<<0, 255, 128, 17>>, 1088)
    :ok = Directory.seed(artifacts, "kubernetes-smoke", "binary-input", bytes)

    {:ok, command} =
      Command.new([
        "python3",
        "-c",
        "import os,pathlib,sys; b=pathlib.Path('/workspace/input').read_bytes(); assert b==bytes([0,255,128,17])*1088; pathlib.Path('/workspace/output').write_bytes(b[::-1]); os.write(1,bytes([0,255,128])); sys.exit(7)"
      ])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "kubernetes-smoke",
        id: id,
        command: command,
        artifact: Source.artifact(hd(target.sources)),
        profile: hd(target.profiles),
        retention_ms: 0,
        inputs: [
          %{
            "source" => "binary-input",
            "path" => "/workspace/input",
            "size" => byte_size(bytes),
            "sha256" => Files.sha256(bytes),
            "mode" => "runtime_default"
          }
        ],
        outputs: [
          %{
            "destination" => "binary-output",
            "path" => "/workspace/output",
            "max_bytes" => byte_size(bytes)
          }
        ]
      )

    spec
  end

  defp wait_clean(settings, key, deadline) do
    true = System.monotonic_time(:millisecond) < deadline
    {:ok, record} = fetch(settings, key)

    if record.cleanup == :complete and record.reservation == nil,
      do: record,
      else:
        (
          Process.sleep(500)
          wait_clean(settings, key, deadline)
        )
  end

  defp summary(settings, record) do
    {adapter, context} = settings.store
    {:ok, usage} = adapter.usage(context, settings.target.id)

    %{
      key: Tuple.to_list(Execution.key(record)),
      state: record.state,
      cleanup: record.cleanup,
      collection: record.collection,
      exit_code: record.result && record.result.exit_code,
      artifacts: record.artifacts,
      deadlines: record.deadlines,
      reserved: record.reservation != nil,
      proof_version: record.backend_cleanup && record.backend_cleanup.version,
      usage: usage,
      pod_uid: record.backend_receipt && record.backend_receipt.pod_uid,
      processes:
        record.backend_receipt && record.backend_receipt.observation &&
          record.backend_receipt.observation.processes
    }
  end

  defp fetch(settings, key) do
    {adapter, context} = settings.store
    adapter.fetch(context, key)
  end

  defp report(root, name, value),
    do:
      File.write!(Path.join(root, name), Jason.encode!(value, pretty: true) <> "\n", [
        :exclusive,
        :sync
      ])
end

SmolBox.NodeAuthorityCampaign.Recovery.main(System.argv())
