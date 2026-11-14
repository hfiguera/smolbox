defmodule SmolBox.KubernetesRuntimeFilesTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Execution, Files, Result, TestArtifacts}
  alias SmolBox.Kubernetes.{Assignment, Receipt}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.Files, as: RuntimeFiles
  alias SmolBox.Runtime.Session
  alias SmolBox.Store.Memory
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  defmodule Artifacts do
    @moduledoc false
    @behaviour SmolBox.ArtifactStore
    @impl true
    def read(context, scope, reference, max),
      do: SmolBox.TestArtifacts.read(context.store, scope, reference, max)

    @impl true
    def put(context, key, destination, bytes, digest) do
      send(context.owner, :put_started)
      Process.sleep(context.delay)
      SmolBox.TestArtifacts.put(context.store, key, destination, bytes, digest)
    end
  end

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-stage-tls-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tls: SmolBox.TestTLS.create(root)}
  end

  setup c do
    {kube, peer} = Peer.start(c.tls)
    %{kube: kube, peer: peer}
  end

  defp prepare(c, options \\ []) do
    now = System.system_time(:millisecond)
    bytes = <<0, 255, 128, 0>>

    input = %{
      "source" => "input",
      "path" => "/workspace/input",
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

    output = %{"destination" => "output", "path" => "/workspace/output", "max_bytes" => 1024}
    profile = %{hd(c.kube.profiles) | collection_ms: Keyword.get(options, :collection_ms, 30_000)}
    kube = %{c.kube | profiles: [profile]}
    {prepared, assignment} = Fixture.ready_record(kube, [inputs: [input], outputs: [output]], now)
    kube = %{kube | node_evidence: {ExecPeer.Proof, prepared.backend_receipt.observation}}
    store = start_supervised!({Memory, []})

    artifacts =
      start_supervised!({Agent, fn -> %{{prepared.scope, "input"} => bytes} end}, id: :artifacts)

    files = start_supervised!({Agent, fn -> %{files: %{}, operations: []} end}, id: :files)
    artifact_store = Keyword.get(options, :artifact_store, {TestArtifacts, artifacts})

    artifact_store =
      if artifact_store == :slow,
        do: {Artifacts, %{store: artifacts, owner: self(), delay: 2500}},
        else: artifact_store

    {config, record} =
      Fixture.runtime(kube, store, artifact_store, {prepared, assignment}, name: __MODULE__)

    {:ok, created} = Receipt.created(assignment, prepared.backend_receipt.pod_uid)

    {:ok, record} =
      Memory.write(
        store,
        Execution.key(record),
        Session.guard(record),
        [backend_create_state: :dispatched, backend_receipt: created],
        now
      )

    {:ok, record} =
      Memory.write(
        store,
        Execution.key(record),
        Session.guard(record),
        [backend_receipt: prepared.backend_receipt, created_machine: prepared.created_machine],
        now
      )

    Peer.change(c.peer, &%{&1 | pod: Peer.effective(Assignment.manifest(assignment), true)})

    c =
      Map.merge(c, %{
        kube: kube,
        config: config,
        record: record,
        session: Session.new(config, record),
        store: store,
        artifacts: artifacts,
        files: files,
        input: input,
        output: output,
        bytes: bytes
      })

    install(c, options)
    c
  end

  defp install(c, options) do
    frames = fn header, data ->
      operation = header["operation"]

      bytes = Agent.get_and_update(c.files, &file_step(&1, operation, header["path"], data))

      bytes =
        if operation == "download" and header["path"] == c.input["path"] and
             options[:wrong_readback], do: "evil", else: bytes

      fields =
        if operation == "download" and header["path"] == c.output["path"] and options[:bad_digest],
          do: %{"sha256" => String.duplicate("0", 64)},
          else: %{}

      ExecPeer.file_frames(operation, header["path"], bytes, fields)
    end

    ExecPeer.install(c.peer, c.record, frames)
  end

  defp file_step(state, "upload", path, data),
    do:
      {data,
       %{
         state
         | files: Map.put(state.files, path, data),
           operations: state.operations ++ ["upload"]
       }}

  defp file_step(state, operation, path, _),
    do: {Map.fetch!(state.files, path), %{state | operations: state.operations ++ [operation]}}

  defp exited(c) do
    {:ok, _} = Session.patch(c.session, state: :ready)
    {:ok, _} = Session.patch(c.session, state: :dispatching, evidence: :dispatch_uncertain)
    result = %Result{exit_code: 7, stdout: <<0, 255>>, stderr: <<128>>, encoding: :bytes}

    {:ok, record} =
      Session.patch(c.session, state: :collecting, evidence: :exited, result: result)

    Agent.update(c.files, &put_in(&1, [:files, c.output["path"]], c.bytes))
    record
  end

  test "Runtime.Files stages with read-back and publishes only validated output bytes", c do
    c = prepare(c)
    assert :ok = RuntimeFiles.stage(c.session, c.record)
    record = exited(c)
    assert {:ok, completed} = RuntimeFiles.collect(c.session, record)
    assert completed.state == :completed and completed.collection == :complete
    assert completed.result.exit_code == 7
    assert [%{"sha256" => digest, "size" => 4}] = completed.artifacts
    assert digest == Files.sha256(c.bytes)

    assert Agent.get(c.artifacts, &Map.fetch!(&1, {Execution.key(record), "output"})) ==
             {c.bytes, digest}

    assert Agent.get(c.files, & &1.operations) == ["upload", "download", "download"]
  end

  test "honest download metadata for changed input cannot satisfy staging read-back", c do
    c = prepare(c, wrong_readback: true)
    assert {:error, %{category: :validation}} = RuntimeFiles.stage(c.session, c.record)
    refute_received :put_started
    assert Agent.get(c.files, & &1.operations) == ["upload", "download"]

    assert {:ok, %{state: :preparing, result: nil, artifacts: []}} =
             Memory.fetch(c.store, Execution.key(c.record))
  end

  test "corrupt file response fails collection without publishing or replacing the application exit",
       c do
    c = prepare(c, bad_digest: true)
    assert :ok = RuntimeFiles.stage(c.session, c.record)
    record = exited(c)
    assert {:ok, failed} = RuntimeFiles.collect(c.session, record)
    assert failed.state == :collection_failed and failed.artifacts == []
    assert failed.result.exit_code == 7
    refute Agent.get(c.artifacts, &Map.has_key?(&1, {Execution.key(record), "output"}))
    assert Agent.get(c.files, & &1.operations) == ["upload", "download", "download"]
  end

  test "artifact callback deadline cannot publish a fabricated receipt or replay the guest command",
       c do
    c = prepare(c, artifact_store: :slow, collection_ms: 1000)
    assert :ok = RuntimeFiles.stage(c.session, c.record)
    record = exited(c)
    assert {:ok, failed} = RuntimeFiles.collect(c.session, record)
    assert_receive :put_started
    assert failed.state == :collection_failed and failed.artifacts == []
    assert failed.result.exit_code == 7
    refute Agent.get(c.artifacts, &Map.has_key?(&1, {Execution.key(record), "output"}))
    refute "exec" in Agent.get(c.files, & &1.operations)
  end
end
