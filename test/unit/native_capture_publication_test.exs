defmodule SmolBox.NativeCapturePublicationTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedCapture, EmbeddedContext}

  alias SmolBox.Embedded.{CapturePublication, Config}

  alias SmolBox.{CheckpointCapture, CheckpointCaptureSpec, CheckpointPolicy}
  alias SmolBox.Runtime.Checkpoints
  alias SmolBox.Store.{Memory, NativeCaptureContract}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)

  defp fixture do
    [proof, _] =
      @fixtures |> Path.join("capture-transitions-v1.json") |> File.read!() |> Jason.decode!()

    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-capture-publication-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "capture",
        root: root,
        max_bytes: 1_048_576,
        resources: %{slots: 1, cpus: 1, memory_mb: 256, disk_gb: 16}
      )

    {:ok, spec} = CheckpointCaptureSpec.new(id: "capture-1", policy: policy, idle: true)

    {:ok, capture} =
      CheckpointCapture.new({"scope", "machine"}, spec, String.duplicate("a", 64), 1000)

    capture = %{capture | state: :dispatching}

    request = %{
      "operation" => "capture_checkpoint",
      "receipt" => proof["previous"],
      "operation_id" => "capture-1",
      "request" => proof["change"]["intent"]["request"]
    }

    budget = %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 256}
    {capture, request, budget, proof}
  end

  defp success(proof),
    do:
      {:ok, %{"result" => "captured", "transition" => proof},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

  test "publication hashes the opened descriptor syncs and creates final bytes without clobber" do
    {capture, request, budget, proof} = fixture()

    transfer = fn consumer, reduced ->
      assert reduced.timeout_ms <= budget.timeout_ms
      assert :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
      assert :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
      success(proof)
    end

    assert {:ok, %{size_bytes: 512, sha256: digest, native_transition: transition}} =
             CapturePublication.receive(capture, request, budget, transfer)

    assert digest == proof["change"]["artifact"]["sha256"]
    assert transition.receipt == proof["receipt"]
    path = CheckpointCapture.path(capture)
    assert File.read!(path) == String.duplicate("c", 512)
    assert File.lstat(path <> ".partial") == {:error, :enoent}
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:error, %{evidence: :dispatch_uncertain}} =
             CapturePublication.receive(capture, request, budget, fn _, _ ->
               flunk("must not replay")
             end)

    assert File.read!(path) == String.duplicate("c", 512)
  end

  test "wrong bytes or incomplete outcome retain private partial without publication" do
    {capture, request, budget, proof} = fixture()

    assert {:error, %{evidence: :dispatch_uncertain}} =
             CapturePublication.receive(capture, request, budget, fn consumer, _ ->
               :ok = consumer.({:checkpoint, String.duplicate("d", 256)})
               success(proof)
             end)

    path = CheckpointCapture.path(capture)
    assert File.lstat(path) == {:error, :enoent}
    assert File.read!(path <> ".partial") == String.duplicate("d", 256)
    assert Bitwise.band(File.stat!(path <> ".partial").mode, 0o777) == 0o600
  end

  test "a destination appearing during transfer is preserved without overwrite" do
    {capture, request, budget, proof} = fixture()
    path = CheckpointCapture.path(capture)

    assert {:error, %{evidence: :dispatch_uncertain}} =
             CapturePublication.receive(capture, request, budget, fn consumer, _ ->
               :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
               :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
               File.write!(path, "foreign", [:exclusive])
               success(proof)
             end)

    assert File.read!(path) == "foreign"
    assert File.read!(path <> ".partial") == String.duplicate("c", 512)
  end

  test "replaced directory cannot publish or delete foreign files" do
    {capture, request, budget, proof} = fixture()
    path = CheckpointCapture.path(capture)
    directory = Path.dirname(path)

    assert {:error, %{evidence: :dispatch_uncertain}} =
             CapturePublication.receive(capture, request, budget, fn consumer, _ ->
               :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
               :ok = consumer.({:checkpoint, String.duplicate("c", 256)})
               File.rename!(directory, directory <> ".original")
               File.mkdir!(directory)
               File.chmod!(directory, 0o700)
               File.write!(path <> ".partial", "foreign")
               success(proof)
             end)

    assert File.lstat(path) == {:error, :enoent}
    assert File.read!(path <> ".partial") == "foreign"
  end

  test "request mismatch rejects before opening staging and current descriptor cannot admit capture" do
    {capture, request, budget, _proof} = fixture()

    assert {:error, %{evidence: :not_dispatched}} =
             CapturePublication.receive(
               capture,
               Map.put(request, "operation_id", "foreign"),
               budget,
               fn _, _ -> flunk("must not dispatch") end
             )

    assert File.lstat(Path.dirname(CheckpointCapture.path(capture))) == {:error, :enoent}
    config = struct(Config, checkpoint_policies: [capture.spec.policy])
    context = %EmbeddedContext{config: config, server: self(), capture: capture}

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCapture.prepare(
               context,
               "vm",
               CheckpointCapture.path(capture),
               capture.spec.policy.max_bytes,
               budget
             )
  end

  test "subsequent native preflight uses current material rather than the original receipt" do
    store = start_supervised!(Memory)
    record = NativeCaptureContract.run(Memory, store)
    assert Checkpoints.source_matches?(record, record.observed_machine)
    refute Checkpoints.source_matches?(record, record.created_machine)
  end

  test "receiver independently caps bytes before writing an over-budget producer" do
    {capture, request, budget, _proof} = fixture()
    # Reach the byte boundary without racing 4096 filesystem writes against the
    # fixture's unrelated one-second deadline under ordinary parallel test load.
    budget = %{budget | timeout_ms: 10_000}

    assert {:error, %{evidence: :dispatch_uncertain}} =
             CapturePublication.receive(capture, request, budget, fn consumer, _ ->
               for _ <- 1..4096,
                   do: assert(:ok == consumer.({:checkpoint, String.duplicate("x", 256)}))

               assert {:error, _} = consumer.({:checkpoint, "extra"})

               {:error,
                %SmolBox.Error{
                  category: :unknown,
                  operation: :checkpoint,
                  evidence: :dispatch_uncertain
                }}
             end)

    assert File.stat!(CheckpointCapture.path(capture) <> ".partial").size ==
             capture.spec.policy.max_bytes
  end
end
