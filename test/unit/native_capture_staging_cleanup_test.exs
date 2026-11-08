defmodule SmolBox.Embedded.CaptureStagingCleanupTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    Channel,
    Protocol,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp cleanup do
    [proof, _] = fixture("capture-resolutions-v1.json")

    %{
      "schema" => 1,
      "previous" => proof["previous"],
      "operation_id" => proof["change"]["intent"]["operation_id"],
      "request" => proof["change"]["intent"]["request"],
      "stage_sha256" => String.duplicate("d", 64)
    }
  end

  defp request(proof, operation),
    do: %{
      "operation" => operation,
      "receipt" => proof["previous"],
      "operation_id" => proof["operation_id"],
      "request" => proof["request"],
      "quiesced" => true
    }

  defp channel(proof, operation) do
    hello =
      fixture("hello-v2.json")["hello"]
      |> Map.put("domain", %{
        "target_id" => proof["previous"]["target_id"],
        "generation" => proof["previous"]["domain_generation"]
      })

    assert {:ok, 1, channel} =
             Channel.register(Channel.new(hello), request(proof, operation), 0, 0)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    {hello, channel}
  end

  defp terminal(hello, proof, result),
    do: %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "outcome" => %{"result" => result, "cleanup" => proof}
    }

  test "cleanup authority is exact, redacted and distinct from artifact completion" do
    wire = cleanup()
    assert {:ok, proof} = CaptureStagingCleanupReceipt.from_wire(wire)

    assert CaptureStagingCleanupReceipt.bound?(
             proof,
             wire["previous"],
             wire["operation_id"],
             wire["request"]
           )

    refute CaptureStagingCleanupReceipt.bound?(
             proof,
             wire["previous"],
             "foreign",
             wire["request"]
           )

    refute inspect(proof) =~ wire["previous"]["owner_token"]
    assert :error = CaptureTransition.from_wire(wire)

    for malformed <- [
          nil,
          false,
          [],
          %{},
          Map.put(wire, "artifact", %{}),
          Map.put(wire, "schema", 2),
          Map.put(wire, "stage_sha256", String.duplicate("A", 64)),
          update_in(wire, ["previous"], &Map.delete(&1, "material"))
        ],
        do: assert(:error == CaptureStagingCleanupReceipt.from_wire(malformed))

    for field <- Map.keys(wire),
        do: assert(:error == CaptureStagingCleanupReceipt.from_wire(Map.delete(wire, field)))
  end

  test "cleanup uses finite protocol-two control authority and stays quarantined" do
    for {operation, _result} <- [
          {"cleanup_capture_staging", "capture_staging_cleaned"},
          {"abort_capture_staging", "capture_staging_aborted"}
        ] do
      proof = cleanup()
      request = request(proof, operation)
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1000, 1)
      refute Request.observation?(request)
      assert Request.control?(request)
      assert Request.reconciliation?(request)

      for value <- [false, nil, "true", 1] do
        invalid = Map.put(request, "quiesced", value)
        refute Request.valid?(invalid, 1000, 2)
        refute Request.control?(invalid)
        refute Request.reconciliation?(invalid)
      end

      refute Request.control?(Map.put(request, "path", "/tmp/foreign"))
      {hello, channel} = channel(proof, operation)

      assert {:ok, quarantined, :unavailable} =
               Channel.receive_message(channel, %{
                 "type" => "unavailable",
                 "epoch" => hello["epoch"]
               })

      assert {:ok, 2, registered} = Channel.register(quarantined, request, 0, 0)
      assert registered.unavailable
      assert :error = Channel.register(quarantined, Map.put(request, "quiesced", false), 0, 0)
    end
  end

  test "cleanup reply binds original intent and cannot substitute stream or material results" do
    for {operation, result} <- [
          {"cleanup_capture_staging", "capture_staging_cleaned"},
          {"abort_capture_staging", "capture_staging_aborted"}
        ] do
      proof = cleanup()
      {hello, channel} = channel(proof, operation)
      message = terminal(hello, proof, result)
      assert {:ok, _} = Protocol.decode(Jason.encode!(message), 2)
      assert :error = Protocol.decode(Jason.encode!(message), 1)

      for crossed <- [
            Map.put(proof, "operation_id", "foreign"),
            put_in(proof, ["previous", "owner_token"], String.duplicate("f", 64)),
            put_in(proof, ["request", "max_bytes"], proof["request"]["max_bytes"] + 1)
          ] do
        assert :error = Channel.receive_message(channel, terminal(hello, crossed, result))
      end

      assert :error =
               Channel.receive_message(
                 channel,
                 put_in(message, ["outcome"], %{
                   "result" => "capture_presence",
                   "transition" => nil
                 })
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

      other =
        if result == "capture_staging_cleaned",
          do: "capture_staging_aborted",
          else: "capture_staging_cleaned"

      assert :error = Channel.receive_message(channel, terminal(hello, proof, other))
      assert {:ok, _, _} = Channel.receive_message(channel, message)
    end
  end
end
