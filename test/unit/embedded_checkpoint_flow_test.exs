defmodule SmolBox.Embedded.CheckpointFlowTest do
  use ExUnit.Case, async: true

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedCapture,
    EmbeddedCaptureCleanup,
    EmbeddedCaptureObservation,
    EmbeddedCaptureResolution,
    EmbeddedContext,
    EmbeddedReply
  }

  alias SmolBox.{CheckpointCapture, Checkpoints, Error}
  alias SmolBox.Embedded.{CaptureTransition, Identity, NativeCaptureResolution}
  alias SmolBox.Store.{CaptureOps, Memory, NativeCaptureContract}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:health, _, {health, _} = state), do: {:reply, {:ok, health}, state}

    def handle_call({:submit, request, _budget, observer, _timeout, epoch}, _, {health, replies}) do
      [{operation, receipt, outcome, chunks} | remaining] = replies
      ^epoch = health.epoch
      %{"operation" => ^operation} = request
      ^receipt = request["receipt"]
      handle = make_ref()
      send(observer, {:smolbox_embedded, handle, :accepted})
      Enum.each(chunks, &send(observer, {:smolbox_embedded, handle, {:output, :checkpoint, &1}}))
      send(observer, {:smolbox_embedded, handle, {:terminal, outcome, nil}})
      {:reply, {:ok, handle}, {health, remaining}}
    end

    def handle_call({:acknowledge, _, _}, _, state), do: {:reply, :ok, state}
    def handle_call(:remaining, _, {_, remaining} = state), do: {:reply, remaining, state}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-capture-flow-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.chmod!(root, 0o700)
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    %{config: config, root: root}
  end

  test "capture dispatch publishes correlated bytes through the checkpoint stream", fixture do
    [wire, _] = wire("capture-transitions-v1.json")
    {context, proof} = context(fixture, :capture)
    request = capture_request(context)
    path = CheckpointCapture.path(context.capture)
    refute Embedded.supports_operation?(context, :capture_checkpoint)

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Embedded.invoke(
               context,
               :capture_checkpoint,
               [context.name, path, 1_048_576],
               budget()
             )

    assert {:error, %{category: :validation}} =
             Embedded.invoke(context, :capture_checkpoint, [context.name], budget())

    deadline = deadline()

    assert {:error, %{category: :expired}} =
             EmbeddedCapture.transfer(%{context | server: nil}, request, budget(), deadline)

    bytes = String.duplicate("c", 256)
    outcome = %{"result" => "captured", "transition" => wire}
    context = connect(context, [{"capture_checkpoint", proof.previous, outcome, [bytes, bytes]}])

    assert {:ok, %{size_bytes: 512, native_transition: ^proof}} =
             EmbeddedCapture.transfer(context, request, budget(), deadline)

    assert File.read!(path) == bytes <> bytes
    assert GenServer.call(context.server, :remaining) == []
  end

  test "read-only lookup promotes a recorded resolution before inspecting the owner", fixture do
    [wire, _] = wire("capture-resolutions-v1.json")
    {context, proof} = context(fixture, :resolution)

    context =
      connect(context, [
        presence("inspect_capture", "capture_presence", proof.previous, nil),
        presence(
          "inspect_capture_resolution",
          "capture_resolution_presence",
          proof.previous,
          wire
        ),
        inspection(context, proof.receipt, "stopped", nil)
      ])

    assert {:error, %{evidence: :dispatch_uncertain}} =
             Embedded.invoke(context, :inspect_machine, [context.name], budget())

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedCaptureObservation.observe(
               context,
               context.name,
               budget(),
               System.monotonic_time(:millisecond) - 1
             )

    assert {:ok, %{state: :stopped, backend_identity: %Identity{transition: ^proof}}} =
             EmbeddedCaptureObservation.observe(context, context.name, budget(), deadline())

    assert context.capture.state == :unknown
    assert context.identity.receipt == proof.previous
    assert GenServer.call(context.server, :remaining) == []
  end

  test "entered resolution follows a confirmed staging rejection and checks the source PID",
       fixture do
    [wire, _] = wire("capture-resolutions-v1.json")
    {context, proof} = context(fixture, :resolution)
    pid = proof.change["intent"]["source_pid"]
    rejected = %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}

    replies = [
      presence("inspect_capture", "capture_presence", proof.previous, nil),
      presence("inspect_capture_resolution", "capture_resolution_presence", proof.previous, nil),
      {"abort_capture_staging", proof.previous, rejected, []},
      presence("resolve_capture", "capture_resolved", proof.previous, wire)
    ]

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Embedded.invoke(context, :qualify_capture, [true], budget())

    ready = connect(context, replies ++ [inspection(context, proof.receipt, "running", pid)])

    assert {:ok, %{state: :running, backend_identity: %Identity{pid_identity: ^pid}}} =
             EmbeddedCaptureResolution.resolve(ready, ready.name, budget(), deadline())

    crossed =
      connect(context, replies ++ [inspection(context, proof.receipt, "running", [123, 999])])

    assert {:error, %{category: :identity_conflict, evidence: :dispatch_uncertain}} =
             EmbeddedCaptureResolution.resolve(crossed, crossed.name, budget(), deadline())

    assert GenServer.call(ready.server, :remaining) == []
    assert GenServer.call(crossed.server, :remaining) == []
  end

  test "pre-entry resolution verifies the unchanged source and retains its cleanup proof",
       fixture do
    [_running, wire] = wire("capture-abort-sources-v1.json")
    {context, proof} = context(fixture, :resolution)
    cleanup = %{"result" => "capture_staging_aborted", "cleanup" => wire["cleanup"]}
    qualified = %{"result" => "aborted_capture_source_qualified", "qualification" => wire}

    context =
      connect(context, [
        presence("inspect_capture", "capture_presence", proof.previous, nil),
        presence(
          "inspect_capture_resolution",
          "capture_resolution_presence",
          proof.previous,
          nil
        ),
        {"abort_capture_staging", proof.previous, cleanup, []},
        {"qualify_aborted_capture_source", proof.previous, qualified, []},
        inspection(context, proof.previous, "stopped", nil)
      ])

    assert {:ok, %NativeCaptureResolution{observed: observed, qualification: qualification}} =
             EmbeddedCaptureResolution.resolve(context, context.name, budget(), deadline())

    assert observed.backend_identity.receipt == proof.previous
    assert qualification.cleanup == wire["cleanup"]
    refute inspect(qualification) =~ proof.previous["owner_token"]
    assert GenServer.call(context.server, :remaining) == []
  end

  test "completed capture remains recorded when the source is absent on inspection", fixture do
    [wire, _] = wire("capture-transitions-v1.json")
    {context, proof} = context(fixture, :capture)
    context = %{context | history: nil}

    missing = %{
      "result" => "observed",
      "observation" => %{"state" => "missing", "resources" => nil, "pid_identity" => nil}
    }

    context =
      connect(context, [
        presence("inspect_capture", "capture_presence", proof.previous, wire),
        {"inspect", proof.receipt, missing, []}
      ])

    assert {:error, %{category: :not_found}} =
             EmbeddedCaptureObservation.observe(context, context.name, budget(), deadline())

    assert context.capture.native_transition == nil
    assert GenServer.call(context.server, :remaining) == []
  end

  test "already recorded source-only proof resolves without another mutation", fixture do
    [wire, _] = wire("capture-resolutions-v1.json")
    {context, proof} = context(fixture, :resolution)

    context =
      connect(context, [
        presence("inspect_capture", "capture_presence", proof.previous, nil),
        presence(
          "inspect_capture_resolution",
          "capture_resolution_presence",
          proof.previous,
          wire
        ),
        inspection(context, proof.receipt, "stopped", nil)
      ])

    assert {:ok, %{state: :stopped, backend_identity: %Identity{transition: ^proof}}} =
             EmbeddedCaptureResolution.resolve(context, context.name, budget(), deadline())

    assert GenServer.call(context.server, :remaining) == []
  end

  test "checkpoint routes preserve disabled admission and check the running observation",
       fixture do
    {context, proof} = context(fixture, :resolution)
    assert Embedded.supports_operation?(nil, :qualify_capture)
    refute Embedded.supports_operation?(context, :qualify_capture)

    assert {:error, %{category: :validation, evidence: :not_dispatched}} =
             Embedded.invoke(context, :qualify_capture, [false], budget())

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             EmbeddedCaptureCleanup.run(context, context.capture, budget())

    pid = proof.change["intent"]["source_pid"]
    {_, _, running, []} = inspection(context, proof.previous, "running", pid)
    {_, _, stopped, []} = inspection(context, proof.previous, "stopped", nil)
    output = %{stdout: <<>>, stderr: <<>>, file: <<>>}

    for operation <- [:start_checkpointable, :checkpoint_preflight] do
      assert {:error, %{category: :unsupported_capability}} =
               Embedded.invoke(context, operation, [context.name], budget())

      assert {:ok, %{state: :running, backend_identity: %Identity{pid_identity: ^pid}}} =
               EmbeddedReply.decode(context, operation, %{}, {:ok, running, output, nil})

      assert {:error, %{category: :identity_conflict, evidence: :dispatch_uncertain}} =
               EmbeddedReply.decode(context, operation, %{}, {:ok, stopped, output, nil})
    end
  end

  test "capture intent binds the exact path, policy, owner and byte ceiling", fixture do
    {context, proof} = context(fixture, :capture)
    context = approved_policy(context, context.capture)
    capture = context.capture
    path = CheckpointCapture.path(capture)
    ceiling = capture.spec.policy.max_bytes
    budget = %{budget() | timeout_ms: capture.spec.timeout_ms + 100, max_response_bytes: 100_000}

    assert {:ok, request, constrained} =
             EmbeddedCapture.prepare_capture(context, context.name, path, ceiling, budget)

    assert request["receipt"] == proof.previous
    assert request["request"] == %{"idle" => true, "max_bytes" => ceiling}
    assert request["chunk_bytes"] == 65_536
    assert constrained.timeout_ms == capture.spec.timeout_ms

    for {input, name, output, maximum} <- [
          {context, "other", path, ceiling},
          {context, context.name, path <> ".other", ceiling},
          {context, context.name, path, ceiling - 1},
          {%{context | identity: nil}, context.name, path, ceiling}
        ] do
      assert {:error, %{evidence: :not_dispatched}} =
               EmbeddedCapture.prepare_capture(input, name, output, maximum, budget)
    end
  end

  test "resolution and cleanup validate durable state and bound the shared budget", fixture do
    {context, proof} = context(fixture, :resolution)
    context = approved_policy(context, context.capture)
    budget = %{budget() | timeout_ms: 60_000, max_response_bytes: 65_536}

    assert {:ok, %{timeout_ms: 30_000, max_response_bytes: 16_384}} =
             EmbeddedCaptureResolution.prepare_capture(context, budget)

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCaptureCleanup.prepare_capture(context, context.capture, budget)

    store = start_supervised!(Memory, id: :cleanup_store)
    record = NativeCaptureContract.entered_resolution(Memory, store, false)
    capture = record.captures["resolve-1"]
    context = approved_policy(context, capture)

    assert {:ok, previous, %{timeout_ms: 30_000, max_response_bytes: 16_384}} =
             EmbeddedCaptureCleanup.prepare_capture(context, capture, budget)

    assert previous == proof.previous

    older = %{capture | native_source_receipt: nil}

    assert {:ok, ^previous, _} =
             EmbeddedCaptureCleanup.prepare_capture(context, older, budget)

    unrecorded = %{older | native_transition: nil}

    assert {:ok, ^previous, _} =
             EmbeddedCaptureCleanup.prepare_capture(context, unrecorded, budget)

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCaptureCleanup.prepare_capture(
               %{context | identity: nil},
               unrecorded,
               budget
             )

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCaptureResolution.prepare_capture(%{context | capture: capture}, budget)
  end

  test "transport errors retain dispatch evidence when capture control labels the operation" do
    failure = %Error{category: :transport, operation: :embedded, evidence: :dispatch_uncertain}

    assert {:error, %{failure | operation: :inspect}} ==
             EmbeddedCaptureObservation.promote(nil, {:error, failure})

    assert {:error, %{failure | operation: :checkpoint}} ==
             EmbeddedCaptureCleanup.decode(nil, nil, nil, :cleaned, {:error, failure})
  end

  test "native inventory errors keep their category and dispatch evidence", fixture do
    cases = [
      {"output_limit", :output_limit},
      {"database", :store},
      {"unsupported", :unsupported_capability},
      {"overload", :admission_exhausted},
      {"deadline", :expired},
      {"ownership", :identity_conflict},
      {"state", :unknown}
    ]

    replies =
      for {code, _} <- cases do
        outcome = %{"result" => "error", "code" => code, "dispatch" => "not_dispatched"}
        {"list", nil, outcome, []}
      end

    context = connect(%EmbeddedContext{config: fixture.config, server: nil}, replies)

    for {_, category} <- cases do
      assert {:error, %{category: ^category, operation: :list, evidence: :not_dispatched}} =
               Embedded.invoke(context, :list, [], budget())
    end

    assert GenServer.call(context.server, :remaining) == []
  end

  test "malformed checkpoint handles and options reject before accessing a runtime" do
    invalid = {:error, %Error{category: :validation, operation: :checkpoint}}
    handle = {"scope", "machine", "capture"}

    assert Checkpoints.fetch(nil, nil) == invalid
    assert Checkpoints.await(nil, handle, -1) == invalid
    assert Checkpoints.cancel(nil, nil) == invalid
    assert Checkpoints.resolve(nil, nil, 1, quiesced: true) == invalid
    assert Checkpoints.resolve(nil, handle, 1, quiesced: false) == invalid
    assert Checkpoints.resolve(nil, handle, 1, quiesced: true, disposition: :invalid) == invalid
    assert Checkpoints.release(nil, nil, artifacts_removed: true) == invalid
  end

  defp approved_policy(context, capture),
    do: %{
      context
      | config: %{context.config | checkpoint_policies: [capture.spec.policy]},
        spec: %{context.spec | checkpointable: true}
    }

  defp context(fixture, mode) do
    store = start_supervised!(Memory)
    {_, _, sent, spec, proof, _, _} = prepare(store, fixture.root, mode)
    record = capture_state(sent, spec.id, mode)
    assignment = record.backend_assignment
    receipt = proof.previous
    artifact = Map.put(record.spec.artifact, "path", assignment.creation["artifact"]["path"])
    artifact = Map.put(artifact, "max_bytes", assignment.creation["artifact"]["max_bytes"])

    config = %{
      fixture.config
      | id: receipt["target_id"],
        domain_generation: receipt["domain_generation"],
        profiles: [record.spec.profile],
        artifacts: [artifact]
    }

    # The scripted peer exercises the transfer after authorization. Ordinary
    # inspection of its receipt still uses a supported offline assignment.
    context = %EmbeddedContext{
      config: config,
      server: nil,
      assignment: %{assignment | creation: Map.delete(assignment.creation, "checkpointable")},
      identity: %Identity{receipt: receipt},
      profile: record.spec.profile,
      name: record.machine_name,
      spec: %{record.spec | checkpointable: false},
      capture: record.captures[spec.id],
      history: []
    }

    assert EmbeddedContext.scoped?(context)
    {context, proof}
  end

  defp prepare(store, root, :capture),
    do: NativeCaptureContract.prepare(Memory, store, capture_proofs(), root)

  defp prepare(store, root, :resolution),
    do:
      NativeCaptureContract.prepare(
        Memory,
        store,
        NativeCaptureContract.resolution_proofs(),
        root
      )

  defp capture_state(sent, _id, :capture), do: sent

  defp capture_state(sent, id, :resolution) do
    assert {:ok, unknown} = CaptureOps.cancel(sent, id, 1102)
    unknown
  end

  defp connect(context, replies) do
    config = context.config

    health = %{
      status: :ready,
      epoch: String.duplicate("a", 32),
      target_id: config.id,
      generation: config.domain_generation,
      package_identity: config.package_identity,
      package_manifest_sha256: config.package_manifest_sha256
    }

    %{context | server: start_supervised!({Peer, {health, replies}}, id: make_ref())}
  end

  defp capture_proofs do
    Enum.map(wire("capture-transitions-v1.json"), fn value ->
      assert {:ok, proof} = CaptureTransition.from_wire(value)
      proof
    end)
  end

  defp capture_request(context) do
    context
    |> EmbeddedCaptureObservation.request()
    |> Map.merge(%{"operation" => "capture_checkpoint", "chunk_bytes" => 256})
  end

  defp wire(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp presence(operation, result, receipt, wire),
    do: {operation, receipt, %{"result" => result, "transition" => wire}, []}

  defp inspection(context, receipt, state, pid),
    do:
      {"inspect", receipt,
       %{
         "result" => "observed",
         "observation" => %{
           "state" => state,
           "resources" => context.assignment.creation["resources"],
           "pid_identity" => pid
         }
       }, []}

  defp budget,
    do: %Budget{timeout_ms: 5000, max_request_bytes: 1_048_576, max_response_bytes: 256}

  defp deadline, do: System.monotonic_time(:millisecond) + 5000
end
