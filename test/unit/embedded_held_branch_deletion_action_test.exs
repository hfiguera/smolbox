defmodule SmolBox.Embedded.HeldBranchDeletionActionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchDeletionContinuation,
    BranchDeletionResolution,
    Channel,
    HeldBranchDeletionAction,
    Protocol,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "held-branch-deletion-action-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{
      "operation" => "#{row["request"]["action"]}_held_branch_deletion",
      "request" => row["request"]
    }

  defp proof_module(%{"request" => %{"action" => "continue"}}),
    do: BranchDeletionContinuation

  defp proof_module(_), do: BranchDeletionResolution

  defp outcome(row),
    do: %{
      "result" =>
        if(row["request"]["action"] == "continue",
          do: "held_branch_deletion_continued",
          else: "held_branch_deletion_cleaned"
        ),
      "proof" => row["proof"]
    }

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared action grants and typed acknowledgements have exact independent digests" do
    for row <- @rows do
      request = row["request"]
      module = proof_module(row)
      assert HeldBranchDeletionAction.request?(request)
      assert {:ok, proof} = module.from_wire(row["proof"])
      assert module.valid?(proof)
      assert module.to_wire(proof) == row["proof"]
      assert HeldBranchDeletionAction.matches?(proof, request, request["action"])
      assert HeldBranchDeletionAction.platform(request) == row["platform"]
      refute inspect(proof) =~ request["child"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      assert :error = module.from_wire(proof)
      refute module.valid?(Map.put(proof, :extra, true))
      refute module.valid?(Map.put(row["proof"], "backing_removed", true))
      refute module.valid?(Map.put(row["proof"], "proof_sha256", String.duplicate("0", 64)))
      refute module.valid?(Map.put(row["proof"], "deletion_sha256", String.duplicate("0", 64)))

      wrong =
        if module == BranchDeletionContinuation,
          do: BranchDeletionResolution,
          else: BranchDeletionContinuation

      refute wrong.valid?(row["proof"])
      refute BranchDeletionResolution.request?(Map.delete(request, "action"))

      switched =
        Map.put(
          request,
          "action",
          if(request["action"] == "continue", do: "cleanup", else: "continue")
        )

      refute HeldBranchDeletionAction.request?(switched)

      switched =
        Map.put(switched, "request_sha256", HeldBranchDeletionAction.request_digest(switched))

      assert HeldBranchDeletionAction.request?(switched)
      refute HeldBranchDeletionAction.request?(switched, request["action"])
      refute HeldBranchDeletionAction.matches?(proof, switched, switched["action"])
    end

    for malformed <- [nil, [], 1, "invalid", %{}] do
      refute HeldBranchDeletionAction.request?(malformed)
      refute BranchDeletionContinuation.valid?(malformed)
      assert :error = BranchDeletionContinuation.from_wire(malformed)
      refute HeldBranchDeletionAction.matches?(malformed, malformed, "continue")
    end
  end

  test "requests require exact action finite budgets original roots explicit fencing and fresh IDs" do
    released =
      @fixtures |> Path.join("branch-child-absence-v1.json") |> File.read!() |> Jason.decode!()

    for row <- @rows do
      request = operation(row)
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1000, 1)
      assert Request.receipt(request) == row["request"]["child"]
      refute Request.observation?(request)
      assert Request.control?(request) and Request.reconciliation?(request)

      for {path, value} <- [
            {~w(quiesced), false},
            {~w(child material), nil},
            {~w(child owner_token), String.duplicate("0", 64)},
            {~w(operation_id),
             get_in(
               row["request"],
               ~w(completion publication change child_origin intent child operation_id)
             )}
          ] do
        changed = put_in(row["request"], path, value)

        changed =
          Map.put(changed, "request_sha256", HeldBranchDeletionAction.request_digest(changed))

        refute HeldBranchDeletionAction.request?(changed)
      end

      for foreign <- released, foreign["mode"] != "held" do
        changed = Map.merge(row["request"], Map.take(foreign["request"], ~w(completion child)))

        changed =
          Map.put(changed, "request_sha256", HeldBranchDeletionAction.request_digest(changed))

        refute HeldBranchDeletionAction.request?(changed)
      end

      for key <- ~w(path pid delete source backing_removed) do
        refute Request.valid?(Map.put(request, key, true), 1000, 2)
        refute Request.valid?(update_in(request, ["request"], &Map.put(&1, key, true)), 1000, 2)
      end

      refute Protocol.valid_outcome?(Map.delete(outcome(row), "proof"), 2)
      refute Protocol.valid_outcome?(Map.put(outcome(row), "proof", nil), 2)
    end
  end

  test "channel admits fenced actions while unavailable and rejects cross action streams and foreign bindings" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | platform: row["platform"], unavailable: true}
      assert {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

      assert {:ok, channel, {1, :accepted}} =
               Channel.receive_message(channel, %{
                 "type" => "accepted",
                 "epoch" => channel.epoch,
                 "id" => 1,
                 "sequence" => 0
               })

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      for stream <- ~w(stdout stderr file checkpoint log terminal) do
        assert :error =
                 Channel.receive_message(channel, %{
                   "type" => "event",
                   "epoch" => channel.epoch,
                   "id" => 1,
                   "sequence" => 1,
                   "event" => %{"stream" => stream, "data_base64" => Base.encode64("extra")}
                 })
      end

      for kind <-
            ~w(held_branch_deletion_resolved held_branch_deletion_continued held_branch_deletion_cleaned),
          kind != outcome(row)["result"] do
        assert :error =
                 Channel.receive_message(
                   channel,
                   terminal(channel, Map.put(outcome(row), "result", kind))
                 )
      end

      other = if row["platform"] == "macos", do: "linux", else: "macos"

      assert :error =
               Channel.register(
                 %{channel | platform: other, pending: %{}, last_id: 0},
                 operation(row),
                 0,
                 0
               )

      crossed =
        put_in(operation(row), ~w(request child domain_generation), String.duplicate("e", 32))

      assert :error = Channel.register(%{channel | pending: %{}, last_id: 0}, crossed, 0, 0)
      changed = put_in(operation(row), ~w(request operation_id), "different-action")

      changed =
        put_in(
          changed,
          ~w(request request_sha256),
          HeldBranchDeletionAction.request_digest(changed["request"])
        )

      assert Request.valid?(changed, 1000, 2)

      assert {:ok, _, mismatch} =
               Channel.register(%{channel | pending: %{}, last_id: 0}, changed, 0, 0)

      assert :error = Channel.receive_message(mismatch, terminal(mismatch, outcome(row)))
    end
  end
end
