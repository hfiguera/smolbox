defmodule SmolBox.NativeCaptureResolutionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{EmbeddedCaptureObservation, EmbeddedContext}
  alias SmolBox.Embedded.{CaptureTransition, Identity, NativeCapture}
  alias SmolBox.Store.{CaptureOps, Memory, NativeCaptureContract}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)

  for state <- [:running, :stopped] do
    test "unknown result resolves #{state} source with exact completed proof without artifact adoption" do
      store = start_supervised!(Memory)
      NativeCaptureContract.unknown_resolution(Memory, store, unquote(state))
    end
  end

  test "recorded source-only resolution promotes observation without importing durable history" do
    store = start_supervised!(Memory)

    {_, _, sent, spec, proof, crossed, _} =
      NativeCaptureContract.prepare(Memory, store, NativeCaptureContract.resolution_proofs())

    assert {:ok, unknown} = CaptureOps.cancel(sent, spec.id, 1102)

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: %Identity{receipt: proof.previous},
      capture: unknown.captures[spec.id],
      history: []
    }

    wire = fn proof ->
      proof |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    end

    reply = fn proof ->
      {:ok, %{"result" => "capture_resolution_presence", "transition" => wire.(proof)},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    assert {:error, _} = EmbeddedCaptureObservation.promote(context, reply.(proof))

    assert {:ok, promoted} =
             EmbeddedCaptureObservation.promote(
               context,
               reply.(proof),
               "capture_resolution_presence"
             )

    assert promoted.identity.receipt == proof.receipt
    assert promoted.capture.state == :unknown and promoted.capture.native_transition == nil

    assert {:error, _} =
             EmbeddedCaptureObservation.promote(
               context,
               reply.(crossed),
               "capture_resolution_presence"
             )

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCaptureObservation.promote(
               context,
               {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"},
                %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil},
               "capture_resolved"
             )
  end

  test "read-only promotion binds exact operation/request and preserves durable uncertainty" do
    store = start_supervised!(Memory)

    {_original, _running, sent, spec, _proof, _, _usage} =
      NativeCaptureContract.prepare(Memory, store)

    assert {:ok, unknown} = CaptureOps.cancel(sent, spec.id, 1102)

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: %Identity{receipt: sent.created_machine.backend_identity.receipt},
      capture: unknown.captures[spec.id],
      history: []
    }

    [first, second] =
      @fixtures |> Path.join("capture-transitions-v1.json") |> File.read!() |> Jason.decode!()

    reply = fn wire ->
      {:ok, %{"result" => "capture_presence", "transition" => wire},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    assert EmbeddedCaptureObservation.request(context)["operation_id"] == spec.id
    assert {:ok, ^context} = EmbeddedCaptureObservation.promote(context, reply.(nil))
    assert {:ok, promoted} = EmbeddedCaptureObservation.promote(context, reply.(first))
    assert promoted.capture == context.capture and promoted.capture.state == :unknown
    assert unknown.observed_machine.backend_identity.receipt == first["previous"]
    assert promoted.identity.receipt == first["receipt"]
    assert {:error, _} = EmbeddedCaptureObservation.promote(context, reply.(second))

    assert {:error, _} =
             EmbeddedCaptureObservation.promote(
               %{context | capture: %{context.capture | state: :accepted}},
               reply.(first)
             )

    assert {:error, _} =
             EmbeddedCaptureObservation.promote(
               context,
               reply.(put_in(first, ["change", "intent", "source_pid"], [123, 457]))
             )

    observed = %{
      unknown.observed_machine
      | backend_identity: %{promoted.identity | pid_identity: [123, 456]}
    }

    assert NativeCapture.resolution_valid?(unknown, unknown.captures[spec.id], observed)

    refute NativeCapture.resolution_valid?(unknown, unknown.captures[spec.id], %{
             observed
             | backend_identity: %Identity{receipt: first["receipt"]}
           })

    assert {:ok, %CaptureTransition{}} = CaptureTransition.from_wire(first)
  end
end
