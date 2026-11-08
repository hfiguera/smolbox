defmodule SmolBox.Embedded.CaptureAbortSourceTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    Channel,
    Protocol,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp request(proof),
    do: %{
      "operation" => "qualify_aborted_capture_source",
      "receipt" => proof["cleanup"]["previous"],
      "operation_id" => proof["cleanup"]["operation_id"],
      "request" => proof["cleanup"]["request"],
      "quiesced" => true
    }

  defp terminal(hello, proof),
    do: %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "outcome" => %{"result" => "aborted_capture_source_qualified", "qualification" => proof}
    }

  test "engine and wire fixtures preserve exact original source material and proof domain" do
    for wire <- fixture("capture-abort-sources-v1.json") do
      assert {:ok, proof} = CaptureAbortSourceQualification.from_wire(wire)

      assert CaptureAbortSourceQualification.bound?(
               proof,
               wire["cleanup"]["previous"],
               wire["cleanup"]["operation_id"],
               wire["cleanup"]["request"]
             )

      refute CaptureAbortSourceQualification.bound?(
               proof,
               wire["cleanup"]["previous"],
               "foreign",
               wire["cleanup"]["request"]
             )

      refute inspect(proof) =~ wire["cleanup"]["previous"]["owner_token"]

      for module <- [CaptureTransition, CaptureResolutionTransition, CaptureStagingCleanupReceipt],
          do: assert(:error == module.from_wire(wire))

      for field <- Map.keys(wire),
          do: assert(:error == CaptureAbortSourceQualification.from_wire(Map.delete(wire, field)))

      for changed <- [
            Map.put(wire, "state", "created"),
            Map.put(wire, "state", nil),
            Map.put(wire, "artifact", %{}),
            Map.put(wire, "schema", 2),
            Map.put(wire, "record_sha256", String.duplicate("f", 64)),
            put_in(wire, ["intent", "source_pid"], [123, 999]),
            put_in(wire, ["intent", "previous_head"], String.duplicate("d", 32)),
            update_in(wire, ["intent"], &Map.delete(&1, "previous_head"))
          ],
          do:
            assert(:error == CaptureAbortSourceQualification.from_wire(changed), inspect(changed))
    end
  end

  test "aborted source qualification is bounded quarantined control with exact reply correlation" do
    for proof <- fixture("capture-abort-sources-v1.json") do
      request = request(proof)
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1000, 1)
      assert Request.control?(request)
      assert Request.reconciliation?(request)
      refute Request.observation?(request)

      for bad <- [false, nil, 1, "true"] do
        invalid = Map.put(request, "quiesced", bad)
        refute Request.valid?(invalid, 1000, 2)
        refute Request.control?(invalid)
      end

      hello =
        fixture("hello-v2.json")["hello"]
        |> Map.put("domain", %{
          "target_id" => proof["cleanup"]["previous"]["target_id"],
          "generation" => proof["cleanup"]["previous"]["domain_generation"]
        })

      assert {:ok, 1, channel} = Channel.register(Channel.new(hello), request, 0, 0)

      assert {:ok, channel, _} =
               Channel.receive_message(channel, %{
                 "type" => "accepted",
                 "epoch" => hello["epoch"],
                 "id" => 1,
                 "sequence" => 0
               })

      for crossed <- [
            Map.put(request, "operation_id", "foreign"),
            put_in(request, ["request", "max_bytes"], request["request"]["max_bytes"] + 1)
          ] do
        assert {:ok, 1, other} = Channel.register(Channel.new(hello), crossed, 0, 0)

        assert {:ok, other, _} =
                 Channel.receive_message(other, %{
                   "type" => "accepted",
                   "epoch" => hello["epoch"],
                   "id" => 1,
                   "sequence" => 0
                 })

        assert :error = Channel.receive_message(other, terminal(hello, proof))
      end

      message = terminal(hello, proof)
      assert {:ok, _} = Protocol.decode(Jason.encode!(message), 2)
      assert :error = Protocol.decode(Jason.encode!(message), 1)

      for outcome <- [
            %{"result" => "capture_staging_aborted", "cleanup" => proof["cleanup"]},
            %{"result" => "capture_presence", "transition" => nil},
            %{
              "result" => "capture_resolved",
              "transition" => fixture("capture-resolutions-v1.json") |> hd()
            }
          ],
          do:
            assert(
              :error == Channel.receive_message(channel, Map.put(message, "outcome", outcome))
            )

      assert :error =
               Channel.receive_message(channel, %{
                 "type" => "event",
                 "epoch" => hello["epoch"],
                 "id" => 1,
                 "sequence" => 1,
                 "event" => %{
                   "stream" => "checkpoint",
                   "data_base64" => Base.encode64("artifact")
                 }
               })

      assert {:ok, quarantined, :unavailable} =
               Channel.receive_message(channel, %{
                 "type" => "unavailable",
                 "epoch" => hello["epoch"]
               })

      assert {:ok, 2, registered} = Channel.register(quarantined, request, 0, 0)
      assert registered.unavailable
      assert :error = Channel.register(quarantined, Map.put(request, "quiesced", false), 0, 0)
      assert {:ok, _, _} = Channel.receive_message(channel, message)
    end
  end
end
