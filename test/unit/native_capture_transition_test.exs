defmodule SmolBox.Embedded.CaptureTransitionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{CaptureStream, CaptureTransition, Channel, Protocol, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  test "checkpoint chunks have bounded consumer acceptance and incremental whole digest" do
    [first, _] = fixture("capture-transitions-v1.json")

    request = %{
      "operation" => "capture_checkpoint",
      "receipt" => first["previous"],
      "operation_id" => "capture-1",
      "request" => first["change"]["intent"]["request"]
    }

    payload = String.duplicate("c", 512)
    stream = CaptureStream.new(1_048_576)

    assert {:ok, stream} =
             CaptureStream.feed(stream, binary_part(payload, 0, 256), fn {:checkpoint, bytes} ->
               assert byte_size(bytes) == 256
               :ok
             end)

    refute CaptureStream.complete?(
             stream,
             %{"result" => "captured", "transition" => first},
             request
           )

    assert {:ok, stream} =
             CaptureStream.feed(stream, binary_part(payload, 256, 256), fn _ -> :ok end)

    assert stream.bytes == 512

    assert CaptureStream.complete?(
             stream,
             %{"result" => "captured", "transition" => first},
             request
           )

    assert :error = CaptureStream.feed(stream, "x", fn _ -> {:error, :closed} end)
    assert :error = CaptureStream.feed(stream, "x", fn _ -> raise "consumer closed" end)
    assert :error = CaptureStream.feed(stream, "x", nil)

    assert :error =
             CaptureStream.feed(stream, String.duplicate("x", 65_537), fn _ ->
               flunk("oversized callback")
             end)

    assert :error =
             CaptureStream.feed(CaptureStream.new(1), "xx", fn _ ->
               flunk("over limit callback")
             end)

    assert :error = CaptureStream.feed(stream, "", fn _ -> flunk("empty callback") end)

    assert {:ok, wrong} =
             CaptureStream.feed(CaptureStream.new(1024), String.duplicate("d", 512), fn _ ->
               :ok
             end)

    refute CaptureStream.complete?(
             wrong,
             %{"result" => "captured", "transition" => first},
             request
           )

    refute CaptureStream.complete?(
             stream,
             %{"result" => "captured", "transition" => first},
             Map.put(request, "operation_id", "crossed")
           )
  end

  test "artifact stream uses distinct limits and credits without widening ordinary file sequences" do
    [first, second] = fixture("capture-transitions-v1.json")

    hello =
      fixture("hello-v2.json")["hello"]
      |> Map.put("domain", %{
        "target_id" => first["previous"]["target_id"],
        "generation" => first["previous"]["domain_generation"]
      })

    request = %{
      "operation" => "capture_checkpoint",
      "receipt" => first["previous"],
      "operation_id" => "capture-1",
      "request" => first["change"]["intent"]["request"]
    }

    assert Request.valid?(request, 600_000, 2)
    assert Request.valid?(Map.put(request, "chunk_bytes", 256), 600_000, 2)

    for invalid <- [nil, false, 0, 65_537, "256"],
        do: refute(Request.valid?(Map.put(request, "chunk_bytes", invalid), 600_000, 2))

    refute Request.valid?(request, 1000, 1)
    assert {:ok, 1, channel} = Channel.register(Channel.new(hello), request, 512, 1)

    assert {:ok, 1, bounded} =
             Channel.register(Channel.new(hello), Map.put(request, "chunk_bytes", 256), 512, 1)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    event = %{
      "type" => "event",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "event" => %{
        "stream" => "checkpoint",
        "data_base64" => Base.encode64(String.duplicate("c", 512))
      }
    }

    assert {:ok, _} = Protocol.decode(Jason.encode!(event), 2)

    assert {:ok, bounded, _} =
             Channel.receive_message(bounded, %{
               "type" => "accepted",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    assert :error = Channel.receive_message(bounded, event)

    assert {:ok, _bounded, _} =
             Channel.receive_message(
               bounded,
               put_in(event, ["event", "data_base64"], Base.encode64(String.duplicate("c", 256)))
             )

    assert :error = Protocol.decode(Jason.encode!(event), 1)
    assert :error = Channel.receive_message(channel, put_in(event, ["event", "stream"], "file"))
    assert {:ok, channel, _} = Channel.receive_message(channel, event)
    assert :error = Channel.receive_message(channel, Map.put(event, "sequence", 2))
    assert {:ok, channel, %{events: 1}} = Channel.acknowledge(channel, 1, 512)

    outcome = %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 2,
      "outcome" => %{"result" => "captured", "transition" => first}
    }

    assert :error =
             Channel.receive_message(channel, put_in(outcome, ["outcome", "transition"], second))

    assert {:ok, _closed, _} = Channel.receive_message(channel, outcome)
    high = Map.put(event, "sequence", 65_537)
    assert {:ok, _} = Protocol.decode(Jason.encode!(high), 2)
    assert :error = Protocol.decode(Jason.encode!(put_in(high, ["event", "stream"], "file")), 2)

    assert :error =
             Protocol.decode(
               Jason.encode!(Map.put(high, "sequence", CaptureStream.max_events() + 1)),
               2
             )
  end

  test "shared capture evidence preserves exact hashes and rejects malformed or crossed intent" do
    [first, second] = fixture("capture-transitions-v1.json")

    for wire <- [first, second] do
      assert {:ok, proof} = CaptureTransition.from_wire(wire)
      intent = proof.change["intent"]

      assert CaptureTransition.bound?(
               proof,
               proof.previous,
               intent["operation_id"],
               intent["request"]
             )

      refute CaptureTransition.bound?(proof, proof.previous, "foreign", intent["request"])

      for changed <- [
            put_in(wire, ["change", "intent", "source_pid"], [123, 457]),
            put_in(wire, ["change", "artifact", "size_bytes"], 1_048_577),
            put_in(wire, ["change", "artifact", "parent"], wire["change"]["artifact"]["head"]),
            put_in(wire, ["change", "growth_immutable_sha256"], String.duplicate("f", 64)),
            update_in(wire, ["change", "artifact"], &Map.delete(&1, "parent")),
            Map.put(wire, "unknown", true)
          ],
          do: assert(:error == CaptureTransition.from_wire(changed))
    end

    for malformed <- [nil, false, [], "bad", %{}],
        do: assert(:error == CaptureTransition.from_wire(malformed))

    assert {:ok, proof} = CaptureTransition.from_wire(second)

    refute CaptureTransition.bound?(
             proof,
             first["previous"],
             "capture-2",
             second["change"]["intent"]["request"]
           )
  end

  test "lookup is protocol-2 read-only and correlates a no-output completed result" do
    [first, second] = fixture("capture-transitions-v1.json")

    hello =
      fixture("hello-v2.json")["hello"]
      |> Map.put("domain", %{
        "target_id" => first["previous"]["target_id"],
        "generation" => first["previous"]["domain_generation"]
      })

    operation = %{
      "operation" => "inspect_capture",
      "receipt" => first["previous"],
      "operation_id" => "capture-1",
      "request" => first["change"]["intent"]["request"]
    }

    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    refute Request.valid?(operation, 30_001, 2)
    refute Request.valid?(put_in(operation, ["request", "idle"], false), 1000, 2)
    assert Request.observation?(operation)
    assert Request.reconciliation?(operation)
    channel = Channel.new(hello)
    assert {:ok, 1, channel} = Channel.register(channel, operation, 0, 0)
    accepted = %{"type" => "accepted", "epoch" => hello["epoch"], "id" => 1, "sequence" => 0}
    assert {:ok, channel, _} = Channel.receive_message(channel, accepted)

    terminal = %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "outcome" => %{"result" => "capture_presence", "transition" => first}
    }

    assert {:ok, _} = Protocol.decode(Jason.encode!(terminal), 2)
    assert :error = Protocol.decode(Jason.encode!(terminal), 1)
    crossed = put_in(terminal, ["outcome", "transition"], second)
    assert :error = Channel.receive_message(channel, crossed)
    assert {:ok, _closed, _} = Channel.receive_message(channel, terminal)

    assert {:ok, _closed, _} =
             Channel.receive_message(channel, put_in(terminal, ["outcome", "transition"], nil))

    assert :error =
             Protocol.decode(
               Jason.encode!(update_in(terminal, ["outcome"], &Map.delete(&1, "transition"))),
               2
             )
  end
end
