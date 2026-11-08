defmodule SmolBox.Embedded.PartialBranchCollectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, PartialBranchCollection, Protocol, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-collection-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  defp operation(row), do: %{"operation" => "collect_partial_branch", "request" => row["request"]}

  defp outcome(row),
    do: %{
      "result" => "partial_branch_collected",
      "proof" => row["proof"],
      "platform" => row["platform"]
    }

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  defp accepted(row) do
    channel = %{Channel.new(@hello) | platform: row["platform"], unavailable: true}
    {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

    {:ok, channel, {1, :accepted}} =
      Channel.receive_message(channel, %{
        "type" => "accepted",
        "epoch" => channel.epoch,
        "id" => 1,
        "sequence" => 0
      })

    channel
  end

  test "synthetic canonical readers preserve full creation hashes and redact authority" do
    for row <- @rows do
      assert PartialBranchCollection.request?(row["request"])
      assert {:ok, proof} = PartialBranchCollection.from_wire(row["proof"])
      assert PartialBranchCollection.valid?(proof)
      assert PartialBranchCollection.to_wire(proof) == row["proof"]
      assert PartialBranchCollection.matches?(proof, row["request"])
      refute inspect(proof) =~ row["proof"]["request_sha256"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      assert :error = PartialBranchCollection.from_wire(proof)
    end

    for invalid <- [nil, [], 1, "invalid", %{}] do
      refute PartialBranchCollection.request?(invalid)
      refute PartialBranchCollection.valid?(invalid)
      assert :error = PartialBranchCollection.from_wire(invalid)
    end
  end

  test "exact fenced requests require native source material distinct actions and one finite budget" do
    for row <- @rows do
      op = operation(row)
      assert Request.valid?(op, 30_000, 2)
      refute Request.valid?(op, 30_001, 2)
      refute Request.valid?(op, 1000, 1)
      assert Request.receipt(op) == row["request"]["creation"]["source"]
      assert Request.control?(op) and Request.reconciliation?(op)
      refute Request.observation?(op)

      for key <- ~w(pid path completion backing_removed) do
        refute PartialBranchCollection.request?(Map.put(row["request"], key, true))
        refute Request.valid?(Map.put(op, key, true), 1000, 2)
      end

      for request <- [
            put_in(row["request"], ~w(creation source material), nil),
            Map.put(row["request"], "quiesced", false),
            Map.put(
              row["request"],
              "operation_id",
              get_in(row, ~w(request creation child operation_id))
            )
          ] do
        request =
          Map.put(request, "request_sha256", PartialBranchCollection.request_digest(request))

        refute PartialBranchCollection.request?(request)
      end
    end
  end

  test "reserved control binds platform full frozen creation and zero output while unavailable" do
    for row <- @rows do
      channel = accepted(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      other = if row["platform"] == "macos", do: "linux", else: "macos"

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, Map.put(outcome(row), "platform", other))
               )

      refute Protocol.valid_outcome?(Map.delete(outcome(row), "platform"), 2)
      refute Protocol.valid_outcome?(Map.put(outcome(row), "platform", "foreign"), 2)

      assert :error =
               Channel.receive_message(channel, terminal(channel, %{"result" => "qualified"}))

      pending = Map.update!(channel.pending, 1, &%{&1 | output_bytes: 1})

      assert :error =
               Channel.receive_message(
                 %{channel | pending: pending},
                 terminal(channel, outcome(row))
               )

      changed = put_in(row, ~w(request operation_id), "different-collection")

      changed =
        put_in(
          changed,
          ~w(request request_sha256),
          PartialBranchCollection.request_digest(changed["request"])
        )

      assert PartialBranchCollection.request?(changed["request"])
      crossed = accepted(changed)
      assert :error = Channel.receive_message(crossed, terminal(crossed, outcome(row)))

      crossed_op =
        put_in(
          operation(row),
          ~w(request creation source domain_generation),
          String.duplicate("e", 32)
        )

      crossed_op =
        put_in(
          crossed_op,
          ~w(request request_sha256),
          PartialBranchCollection.request_digest(crossed_op["request"])
        )

      assert :error = Channel.register(Channel.new(@hello), crossed_op, 0, 0)
    end
  end
end
