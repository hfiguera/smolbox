defmodule SmolBox.Embedded.PartialBranchDisposalTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchCanonical, Channel, PartialBranchDisposal, Protocol, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-disposal-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  @operations ~w(dispose_partial_branch resolve_partial_branch_disposal qualify_partial_branch_cleanup)
  defp operation(row, kind), do: %{"operation" => kind, "request" => row["request"]}
  defp outcome(row), do: %{"result" => "partial_branch_disposed", "proof" => row["proof"]}

  defp channel(row, kind) do
    epoch = get_in(row, ~w(proof publication change child_origin intent epoch))
    channel = %{Channel.new(@hello) | epoch: epoch, platform: row["platform"], unavailable: true}
    {:ok, 1, channel} = Channel.register(channel, operation(row, kind), 1024, 1)

    {:ok, channel, {1, :accepted}} =
      Channel.receive_message(channel, %{
        "type" => "accepted",
        "epoch" => epoch,
        "id" => 1,
        "sequence" => 0
      })

    channel
  end

  defp terminal(channel, result),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => result
    }

  test "synthetic canonical readers preserve both completions exact collection and optional release" do
    for row <- @rows do
      request = row["request"]
      assert PartialBranchDisposal.request?(request)
      assert {:ok, proof} = PartialBranchDisposal.from_wire(row["proof"])
      assert PartialBranchDisposal.valid?(proof)
      assert PartialBranchDisposal.to_wire(proof) == row["proof"]
      assert PartialBranchDisposal.matches?(proof, request)
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ request["request_sha256"]
      assert :error = PartialBranchDisposal.from_wire(proof)

      for invalid <- [nil, [], 1, "invalid", %{}] do
        refute PartialBranchDisposal.valid?(invalid)
        refute PartialBranchDisposal.request?(invalid)
      end
    end
  end

  test "both controls bind the full collection source approval and one bounded deadline" do
    for row <- @rows, kind <- @operations do
      op = operation(row, kind)
      assert Request.valid?(op, 30_000, 2)
      refute Request.valid?(op, 30_001, 2)
      refute Request.valid?(op, 1000, 1)
      assert Request.control?(op) and Request.reconciliation?(op)
      refute Request.observation?(op)
      assert Request.receipt(op) == get_in(row, ~w(request collection_request creation source))

      assert PartialBranchDisposal.approval(row["request"]) ==
               get_in(row, ~w(request collection_request creation approval))

      refute Request.valid?(Map.put(op, "path", "/arbitrary"), 1000, 2)
    end
  end

  test "required terminal has zero output exact platform and original epoch even in quarantine" do
    for row <- @rows, kind <- @operations do
      channel = channel(row, kind)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      wrong_platform = if row["platform"] == "macos", do: "linux", else: "macos"

      assert :error =
               Channel.receive_message(
                 %{channel | platform: wrong_platform},
                 terminal(channel, outcome(row))
               )

      other = %{channel | epoch: String.duplicate("0", 32)}
      assert :error = Channel.receive_message(other, terminal(other, outcome(row)))

      assert :error =
               Channel.receive_message(channel, terminal(channel, %{"result" => "qualified"}))

      assert :error =
               Channel.receive_message(channel, %{
                 "type" => "event",
                 "epoch" => channel.epoch,
                 "id" => 1,
                 "sequence" => 1,
                 "stream" => "stdout",
                 "data" => Base.encode64("unexpected")
               })
    end
  end

  test "changed action creation collection or release cannot substitute for an acknowledgement" do
    for row <- @rows do
      request = row["request"]
      crossed = Map.put(request, "operation_id", "other-disposal")
      crossed = Map.put(crossed, "request_sha256", PartialBranchDisposal.request_digest(crossed))
      assert PartialBranchDisposal.request?(crossed)
      refute PartialBranchDisposal.matches?(row["proof"], crossed)
      quiescent = Map.put(request, "quiesced", false)

      quiescent =
        Map.put(quiescent, "request_sha256", PartialBranchDisposal.request_digest(quiescent))

      refute PartialBranchDisposal.request?(quiescent)
      refute PartialBranchDisposal.valid?(Map.put(row["proof"], "backing_removed", true))

      proof =
        put_in(row["proof"], ~w(request collection collection_sha256), String.duplicate("0", 64))

      refute PartialBranchDisposal.valid?(proof)

      assert row["request"]["collection"]["publication_sha256"] ==
               BranchCanonical.digest(
                 BranchCanonical.ordered(row["proof"]["publication"], :publication)
               )
    end
  end
end
