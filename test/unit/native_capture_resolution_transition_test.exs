defmodule SmolBox.Embedded.CaptureResolutionTransitionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    CaptureResolutionTransition,
    CaptureTransition,
    Channel,
    Protocol,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp request(proof, operation),
    do: %{
      "operation" => operation,
      "receipt" => proof["previous"],
      "operation_id" => proof["change"]["intent"]["operation_id"],
      "request" => proof["change"]["intent"]["request"]
    }

  defp channel(proof, request) do
    hello =
      fixture("hello-v2.json")["hello"]
      |> Map.put("domain", %{
        "target_id" => proof["previous"]["target_id"],
        "generation" => proof["previous"]["domain_generation"]
      })

    assert {:ok, 1, channel} = Channel.register(Channel.new(hello), request, 0, 0)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    {hello, channel}
  end

  defp terminal(hello, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared resolution proofs match exact canonical hashes without any capture result" do
    for wire <- fixture("capture-resolutions-v1.json") do
      assert {:ok, proof} = CaptureResolutionTransition.from_wire(wire)

      assert CaptureResolutionTransition.bound?(
               proof,
               wire["previous"],
               wire["change"]["intent"]["operation_id"],
               wire["change"]["intent"]["request"]
             )

      refute CaptureResolutionTransition.bound?(
               proof,
               wire["previous"],
               "foreign",
               wire["change"]["intent"]["request"]
             )

      assert :error = CaptureTransition.from_wire(wire)

      for changed <- [
            put_in(wire, ["change", "intent", "source_pid"], [123, 457]),
            put_in(wire, ["change", "growth_immutable_sha256"], String.duplicate("f", 64)),
            update_in(wire, ["change"], &Map.delete(&1, "checkpoint_head")),
            update_in(wire, ["change", "intent"], &Map.delete(&1, "previous_head")),
            update_in(wire, ["previous"], &Map.delete(&1, "material")),
            update_in(wire, ["change"], &Map.put(&1, "artifact", %{})),
            Map.put(wire, "unknown", true)
          ],
          do: assert(:error == CaptureResolutionTransition.from_wire(changed))
    end

    for malformed <- [nil, false, [], "bad", %{}],
        do: assert(:error == CaptureResolutionTransition.from_wire(malformed))
  end

  test "explicit resolution requires protocol two, finite deadline and positive quiescence" do
    [proof, _] = fixture("capture-resolutions-v1.json")
    request = request(proof, "resolve_capture") |> Map.put("quiesced", true)
    assert Request.valid?(request, 30_000, 2)
    refute Request.valid?(request, 30_001, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.valid?(Map.delete(request, "quiesced"), 1000, 2)

    for invalid <- [nil, false, "true", 1],
        do: refute(Request.valid?(Map.put(request, "quiesced", invalid), 1000, 2))

    refute Request.valid?(Map.put(request, "chunk_bytes", 64), 1000, 2)
    refute Request.observation?(request)
    assert Request.control?(request)
    assert Request.reconciliation?(request)
    refute Request.reconciliation?(Map.put(request, "quiesced", false))
    refute Request.control?(Map.put(request, "quiesced", false))
    refute Request.control?(Map.put(request, "extra", true))
    lookup = request(proof, "inspect_capture_resolution")
    assert Request.valid?(lookup, 30_000, 2)
    refute Request.valid?(lookup, 30_001, 2)
    assert Request.observation?(lookup)
    assert Request.reconciliation?(lookup)
    {hello, channel} = channel(proof, request)

    assert {:ok, quarantined, :unavailable} =
             Channel.receive_message(channel, %{
               "type" => "unavailable",
               "epoch" => hello["epoch"]
             })

    assert {:ok, 2, still_quarantined} = Channel.register(quarantined, request, 0, 0)
    assert still_quarantined.unavailable
    assert {:ok, 2, _} = Channel.register(quarantined, lookup, 0, 0)
    assert :error = Channel.register(quarantined, Map.put(request, "quiesced", false), 0, 0)
    assert :error = Channel.register(quarantined, request(proof, "capture_checkpoint"), 0, 0)
  end

  test "resolution channel binds exact source intent with zero output and a distinct terminal" do
    [proof, crossed] = fixture("capture-resolutions-v1.json")
    request = request(proof, "resolve_capture") |> Map.put("quiesced", true)
    {hello, channel} = channel(proof, request)
    outcome = %{"result" => "capture_resolved", "transition" => proof}
    message = terminal(hello, outcome)
    assert {:ok, _} = Protocol.decode(Jason.encode!(message), 2)
    assert :error = Protocol.decode(Jason.encode!(message), 1)

    assert :error =
             Channel.receive_message(channel, put_in(message, ["outcome", "transition"], crossed))

    assert :error =
             Channel.receive_message(
               channel,
               put_in(message, ["outcome", "result"], "capture_resolution_presence")
             )

    assert :error =
             Channel.receive_message(
               channel,
               terminal(hello, %{"result" => "capture_presence", "transition" => nil})
             )

    assert :error =
             Protocol.decode(Jason.encode!(put_in(message, ["outcome", "transition"], nil)), 2)

    assert :error =
             Channel.receive_message(channel, %{
               "type" => "event",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 1,
               "event" => %{"stream" => "checkpoint", "data_base64" => Base.encode64("artifact")}
             })

    assert {:ok, _channel, _} = Channel.receive_message(channel, message)
  end

  test "resolution lookup preserves null and rejects completion substitution or missing fields" do
    [proof, crossed] = fixture("capture-resolutions-v1.json")
    request = request(proof, "inspect_capture_resolution")
    {hello, channel} = channel(proof, request)
    message = terminal(hello, %{"result" => "capture_resolution_presence", "transition" => proof})

    assert :error =
             Channel.receive_message(channel, put_in(message, ["outcome", "transition"], crossed))

    assert :error =
             Channel.receive_message(
               channel,
               put_in(message, ["outcome", "result"], "capture_resolved")
             )

    assert {:ok, _channel, _} = Channel.receive_message(channel, message)

    assert {:ok, _channel, _} =
             Channel.receive_message(channel, put_in(message, ["outcome", "transition"], nil))

    assert :error =
             Protocol.decode(
               Jason.encode!(update_in(message, ["outcome"], &Map.delete(&1, "transition"))),
               2
             )

    assert :error =
             Protocol.decode(Jason.encode!(put_in(message, ["outcome", "result"], "captured")), 2)
  end
end
