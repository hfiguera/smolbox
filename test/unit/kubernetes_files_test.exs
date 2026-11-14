defmodule SmolBox.KubernetesFilesTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Execution, Files, Machine, Result}
  alias SmolBox.Kubernetes.{Assignment, FileReply}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.Target
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-files-tls-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tls: SmolBox.TestTLS.create(root)}
  end

  setup c do
    {config, peer} = Peer.start(c.tls)
    files = start_supervised!({Agent, fn -> %{} end})
    fixture(%{config: config, peer: peer, files: files}, <<0, 255, 128, 0>>)
  end

  defp fixture(c, bytes) do
    input = %{
      "source" => "input",
      "path" => "/workspace/private-file '☃",
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

    output = %{"destination" => "output", "path" => "/workspace/result", "max_bytes" => 1_048_576}
    {record, assignment} = Fixture.ready_record(c.config, inputs: [input], outputs: [output])
    config = %{c.config | node_evidence: {ExecPeer.Proof, record.backend_receipt.observation}}
    Peer.change(c.peer, &%{&1 | pod: Peer.effective(Assignment.manifest(assignment), true)})
    Map.merge(c, %{config: config, record: record, bytes: bytes, input: input, output: output})
  end

  defp reference(c, budget \\ []),
    do:
      c.config
      |> Target.normalize()
      |> Target.connection()
      |> Backend.assigned(c.record)
      |> Backend.bounded(budget)

  defp frames(operation, path, bytes, fields \\ %{}),
    do: ExecPeer.file_frames(operation, path, bytes, fields)

  defp install(c) do
    handler = fn header, data ->
      case header["operation"] do
        "upload" ->
          Agent.update(c.files, &Map.put(&1, header["path"], data))
          frames("upload", header["path"], data)

        "download" ->
          bytes = Agent.get(c.files, &Map.fetch!(&1, header["path"]))
          frames("download", header["path"], bytes)
      end
    end

    ExecPeer.install(c.peer, c.record, handler)
  end

  defp collecting(c) do
    {:ok, record} =
      Execution.transition(c.record, [state: :dispatching, evidence: :dispatch_uncertain], 1000)

    {:ok, record} =
      Execution.transition(
        record,
        [
          state: :collecting,
          evidence: :exited,
          result: %Result{exit_code: 7, stdout: "", stderr: "", encoding: :bytes}
        ],
        1000
      )

    %{c | record: record}
  end

  test "declared binary upload/read-back uses frozen identity and keeps paths out of the URL",
       c do
    install(c)

    assert :ok =
             Backend.upload(
               reference(c),
               c.record.machine_name,
               c.input["path"],
               c.bytes,
               c.input["sha256"]
             )

    assert {:ok, bytes} =
             Backend.download(reference(c), c.record.machine_name, c.input["path"], 1024)

    assert bytes == c.bytes

    assert {:ok, %Machine{} = observed} =
             Backend.inspect_machine(reference(c), c.record.machine_name)

    assert Machine.same_incarnation?(observed, c.record.created_machine)
    requests = Peer.requests(c.peer) |> Enum.filter(&String.ends_with?(&1.path, "/exec"))
    assert [_first, _second] = requests
    assert Enum.all?(requests, &(byte_size(&1.query) < 8192))
    refute Enum.any?(requests, &String.contains?(&1.query, "private-file"))
  end

  test "empty and one-MiB file boundaries survive backpressure in both directions", c do
    for bytes <- [<<>>, :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 4096)] do
      c = fixture(c, bytes)
      install(c)

      assert :ok =
               Backend.upload(
                 reference(c),
                 c.record.machine_name,
                 c.input["path"],
                 bytes,
                 c.input["sha256"]
               )

      assert {:ok, ^bytes} =
               Backend.download(reference(c), c.record.machine_name, c.input["path"], 1_048_576)
    end
  end

  test "unknown paths, changed input bytes, forbidden state and excess limits reject before upgrade",
       c do
    install(c)

    assert {:error, %{evidence: :not_dispatched}} =
             Backend.upload(
               reference(c),
               c.record.machine_name,
               "/workspace/other",
               c.bytes,
               c.input["sha256"]
             )

    assert {:error, %{evidence: :not_dispatched}} =
             Backend.upload(
               reference(c),
               c.record.machine_name,
               c.input["path"],
               "changed",
               c.input["sha256"]
             )

    assert {:error, _} =
             Backend.download(reference(c), c.record.machine_name, c.output["path"], 10)

    assert {:error, _} =
             Backend.download(reference(c), c.record.machine_name, c.input["path"], 1_048_577)

    after_exit = collecting(c)

    assert {:error, _} =
             Backend.upload(
               reference(after_exit),
               c.record.machine_name,
               c.input["path"],
               c.bytes,
               c.input["sha256"]
             )

    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "collection needs an observed exit and malformed helper data cannot become file bytes",
       c do
    c = collecting(c)
    ExecPeer.install(c.peer, c.record, frames("download", c.output["path"], c.bytes))

    assert {:ok, bytes} =
             Backend.download(reference(c), c.record.machine_name, c.output["path"], 100)

    assert bytes == c.bytes

    for fields <- [
          %{"size" => 100},
          %{"sha256" => String.duplicate("0", 64)},
          %{"path" => "/workspace/foreign"},
          %{"extra" => true}
        ] do
      ExecPeer.install(c.peer, c.record, frames("download", c.output["path"], c.bytes, fields))

      assert {:error, %{category: :protocol, evidence: :exited, exit_code: 0}} =
               Backend.download(reference(c), c.record.machine_name, c.output["path"], 100)
    end

    ExecPeer.install(
      c.peer,
      c.record,
      frames("download", c.output["path"], c.bytes) |> Enum.drop(-1)
    )

    assert {:error, %{evidence: :dispatch_uncertain, exit_code: nil}} =
             Backend.download(reference(c), c.record.machine_name, c.output["path"], 100)
  end

  test "rejected helper request preserves its exit without manufacturing an application result",
       c do
    ExecPeer.install(c.peer, c.record, [
      {:binary, <<2, "private helper diagnostic">>},
      ExecPeer.status(126)
    ])

    assert {:error, error} =
             Backend.download(reference(c), c.record.machine_name, c.input["path"], 100)

    assert {error.exit_code, error.evidence, error.operation} == {126, :exited, :download}
    refute inspect(error) =~ "private helper diagnostic"
    assert c.record.result == nil and c.record.evidence == :not_dispatched
  end

  test "lost upload acknowledgement is uncertain, closes the socket and is never replayed", c do
    ExecPeer.install(c.peer, c.record, [], mode: :hold)

    assert {:error, %{category: :expired, evidence: :dispatch_uncertain}} =
             Backend.upload(
               reference(c, timeout_ms: 2000),
               c.record.machine_name,
               c.input["path"],
               c.bytes,
               c.input["sha256"]
             )

    assert_receive {:exec_request, socket, %{"operation" => "upload"}}
    assert_receive {:exec_socket_closed, ^socket}, 1000
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "lost history and changed observer epoch reject file I/O before upgrade", c do
    install(c)

    for changes <- [%{complete_history: false}, %{observer_epoch: "replacement-epoch"}] do
      observation = Map.merge(c.record.backend_receipt.observation, changes)
      config = %{c.config | node_evidence: {ExecPeer.Proof, observation}}
      changed = %{c | config: config}

      assert {:error, %{category: :identity_conflict, evidence: :not_dispatched}} =
               Backend.download(reference(changed), c.record.machine_name, c.input["path"], 100)
    end

    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "guest path depth and component bounds accompany aggregate manifest limits", c do
    alias SmolBox.Kubernetes.{ExecutionPolicy, GuestHelper}

    for path <- [
          "/workspace/" <> String.duplicate("x", 256),
          "/workspace/" <> Enum.join(List.duplicate("a", 65), "/")
        ] do
      refute GuestHelper.file_path?(path)
      input = Map.put(c.input, "path", path)
      refute ExecutionPolicy.supported?(%{c.record.spec | inputs: [input]})
    end

    outputs =
      for n <- 1..5,
          do: Map.merge(c.output, %{"path" => "/workspace/o#{n}", "destination" => "o#{n}"})

    assert {:error, _} = SmolBox.ExecutionSpec.validate(%{c.record.spec | outputs: outputs})
  end

  test "file reply rejects extra bytes, duplicate keys and short declared data" do
    header =
      ~s({"version":1,"operation":"download","path":"/workspace/a","size":0,"sha256":"#{Files.sha256("")}","size":0})

    assert :error =
             FileReply.decode(
               <<"SBF1", byte_size(header)::32, header::binary>>,
               :download,
               "/workspace/a",
               1
             )

    assert :error = FileReply.decode(<<"SBF1", 8193::32>>, :download, "/workspace/a", 1)
    assert :error = FileReply.decode("broken", :upload, "/workspace/a", 1)
  end
end
