defmodule SmolBox.Embedded.PartialBranchCleanupCandidateTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    Channel,
    PartialBranchCleanupCandidate,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    Protocol,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-cleanup-candidate-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  defp operation(row),
    do: %{"operation" => "qualify_partial_branch_cleanup", "request" => row["request"]}

  defp outcome(row),
    do: %{"result" => "partial_branch_cleanup_candidate", "candidate" => row["candidate"]}

  defp accepted(row) do
    source = get_in(row, ~w(request collection_request creation source))
    epoch = get_in(row, ~w(candidate publication change child_origin intent epoch))

    hello =
      @hello
      |> Map.put("epoch", epoch)
      |> put_in(~w(package platform), row["platform"])
      |> put_in(~w(domain target_id), source["target_id"])
      |> put_in(~w(domain generation), source["domain_generation"])

    channel = %{Channel.new(hello) | unavailable: true}
    assert {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

    assert {:ok, channel, {1, :accepted}} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => epoch,
               "id" => 1,
               "sequence" => 0
             })

    channel
  end

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "synthetic candidate readers preserve exact original request publication and release while redacting authority" do
    for row <- @rows do
      assert {:ok, candidate} = PartialBranchCleanupCandidate.from_wire(row["candidate"])
      assert PartialBranchCleanupCandidate.valid?(candidate)
      assert PartialBranchCleanupCandidate.to_wire(candidate) == row["candidate"]
      assert PartialBranchCleanupCandidate.matches?(candidate, row["request"])
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(candidate) =~ candidate.proof_sha256
      assert :error = PartialBranchCleanupCandidate.from_wire(candidate)
      refute PartialBranchDisposal.valid?(row["candidate"])
      refute PartialBranchDisposalCleanup.valid?(row["candidate"])
    end
  end

  test "qualification uses only exact bounded protocol two control and the original disposal source" do
    for row <- @rows do
      op = operation(row)
      assert Request.valid?(op, 30_000, 2)
      refute Request.valid?(op, 30_001, 2)
      refute Request.valid?(op, 1000, 1)
      assert Request.control?(op) and Request.reconciliation?(op)
      refute Request.observation?(op)
      assert Request.receipt(op) == get_in(row, ~w(request collection_request creation source))
      refute Request.valid?(Map.put(op, "path", "/arbitrary"), 1000, 2)
    end
  end

  test "candidate completion requires exact platform original epoch and zero output in quarantine" do
    for row <- @rows do
      channel = accepted(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      for wrong <- [
            %{channel | platform: "foreign"},
            %{channel | epoch: String.duplicate("0", 32)}
          ] do
        assert :error = Channel.receive_message(wrong, terminal(wrong, outcome(row)))
      end

      for stream <- ~w(stdout stderr file checkpoint log terminal) do
        assert :error =
                 Channel.receive_message(channel, %{
                   "type" => "output",
                   "epoch" => channel.epoch,
                   "id" => 1,
                   "sequence" => 1,
                   "event" => %{"stream" => stream, "data_base64" => Base.encode64("extra")}
                 })
      end

      assert :error =
               Channel.receive_message(channel, terminal(channel, %{"result" => "qualified"}))
    end
  end

  test "a separately valid candidate cannot substitute a different original disposal" do
    for row <- @rows do
      request = Map.put(row["request"], "operation_id", "other-disposal")
      request = Map.put(request, "request_sha256", PartialBranchDisposal.request_digest(request))
      candidate = Map.put(row["candidate"], "request", request)

      candidate =
        Map.put(candidate, "proof_sha256", PartialBranchCleanupCandidate.proof_digest(candidate))

      assert PartialBranchCleanupCandidate.valid?(candidate)
      refute PartialBranchCleanupCandidate.matches?(candidate, row["request"])
      channel = accepted(row)

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, %{
                   "result" => "partial_branch_cleanup_candidate",
                   "candidate" => candidate
                 })
               )
    end
  end

  test "strict schemas reject disposition grants nullable authority and malformed values" do
    for row <- @rows do
      for key <- ~w(completion path pid backing_removed),
          do: refute(PartialBranchCleanupCandidate.valid?(Map.put(row["candidate"], key, true)))

      refute Protocol.valid_outcome?(Map.put(outcome(row), "extra", true), 2)

      refute Protocol.valid_outcome?(
               %{"result" => "partial_branch_cleanup_candidate", "candidate" => nil},
               2
             )

      refute PartialBranchCleanupCandidate.valid?(
               put_in(row["candidate"], ~w(request quiesced), false)
             )
    end

    for value <- [nil, [], %{}, 1, "invalid"],
        do: refute(PartialBranchCleanupCandidate.valid?(value))
  end
end
