defmodule SmolBox.Embedded.BranchDeletionCollectionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchDeletionCollection,
    BranchDeletionResolution,
    Channel,
    Protocol,
    ReleasedBranchDeletionResolution,
    Request
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-deletion-collection-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "collect_branch_deletion", "request" => row["request"]}

  defp outcome(row),
    do: %{"result" => "branch_deletion_collected", "proof" => row["proof"]}

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared original collection proofs validate canonical hashes and redact authority" do
    for row <- @rows do
      assert BranchDeletionCollection.request?(row["request"])
      assert {:ok, proof} = BranchDeletionCollection.from_wire(row["proof"])
      assert BranchDeletionCollection.valid?(proof)
      assert BranchDeletionCollection.to_wire(proof) == row["proof"]
      assert BranchDeletionCollection.matches?(proof, row["request"])
      assert BranchDeletionCollection.platform(row["request"]) == row["platform"]
      refute inspect(proof) =~ row["request"]["child"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
    end

    for malformed <- [nil, [], 1, "invalid", %{}] do
      refute BranchDeletionCollection.request?(malformed)
      refute BranchDeletionCollection.valid?(malformed)
      assert :error = BranchDeletionCollection.from_wire(malformed)
    end
  end

  test "fenced original collection has a finite budget exact keys and no SDK deletion replay authority" do
    for row <- @rows do
      request = operation(row)
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1000, 1)
      assert Request.receipt(request) == row["request"]["child"]

      refute Request.observation?(request)
      assert Request.control?(request) and Request.reconciliation?(request)

      refute Request.valid?(put_in(request, ~w(request quiesced), false), 1000, 2)

      for key <- ~w(path pid delete source backing_removed),
          do: refute(Request.valid?(Map.put(request, key, true), 1000, 2))

      refute Request.valid?(put_in(request, ~w(request child material), nil), 1000, 2)

      refute Request.valid?(
               put_in(request, ~w(request child owner_token), String.duplicate("0", 64)),
               1000,
               2
             )

      refute Protocol.valid_outcome?(
               %{"result" => "branch_deletion_collected", "proof" => nil},
               2
             )

      refute Protocol.valid_outcome?(%{"result" => "branch_deletion_collected"}, 2)
    end
  end

  test "channel binds exact original completion and current child without accepting any output" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | platform: row["platform"]}

      assert {:ok, 1, channel} =
               Channel.register(%{channel | unavailable: true}, operation(row), 1024, 1)

      assert {:ok, channel, {1, :accepted}} =
               Channel.receive_message(channel, %{
                 "type" => "accepted",
                 "epoch" => channel.epoch,
                 "id" => 1,
                 "sequence" => 0
               })

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, %{
                   "result" => "observed",
                   "observation" => %{
                     "state" => "missing",
                     "resources" => nil,
                     "pid_identity" => nil
                   }
                 })
               )

      for stream <- ~w(stdout stderr file checkpoint log terminal) do
        event = %{
          "type" => "event",
          "epoch" => channel.epoch,
          "id" => 1,
          "sequence" => 1,
          "event" => %{"stream" => stream, "data_base64" => Base.encode64("extra")}
        }

        assert :error = Channel.receive_message(channel, event)
      end

      wrong = put_in(operation(row), ~w(request operation_id), "different-observation")
      refute Request.valid?(wrong, 1000, 2)

      wrong =
        put_in(
          wrong,
          ~w(request request_sha256),
          BranchDeletionCollection.request_digest(wrong["request"])
        )

      assert Request.valid?(wrong, 1000, 2)

      assert {:ok, _, mismatched} =
               Channel.register(%{channel | pending: %{}, last_id: 0}, wrong, 1024, 1)

      assert :error = Channel.receive_message(mismatched, terminal(mismatched, outcome(row)))
    end
  end

  test "platform domain proof digest release and history substitutions cannot assert absence" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | platform: row["platform"]}
      other = if row["platform"] == "macos", do: "linux", else: "macos"
      assert :error = Channel.register(%{channel | platform: other}, operation(row), 0, 0)

      crossed =
        put_in(operation(row), ~w(request child domain_generation), String.duplicate("e", 32))

      assert :error = Channel.register(channel, crossed, 0, 0)

      refute BranchDeletionCollection.valid?(
               put_in(row["proof"], ~w(proof_sha256), String.duplicate("0", 64))
             )

      changed = put_in(row["request"], ~w(operation_id), "different-observation")
      refute BranchDeletionCollection.request?(changed)

      changed =
        Map.put(
          changed,
          "request_sha256",
          BranchDeletionCollection.request_digest(changed)
        )

      assert BranchDeletionCollection.request?(changed)
      refute BranchDeletionCollection.matches?(row["proof"], changed)

      refute BranchDeletionCollection.valid?(Map.put(row["proof"], "backing_removed", true))
    end
  end

  test "collection is never an SDK success or absence acknowledgement" do
    for row <- @rows do
      refute ReleasedBranchDeletionResolution.valid?(row["proof"])
      refute BranchDeletionResolution.valid?(row["proof"])
      request = row["request"]

      if Map.has_key?(request, "release") do
        refute BranchDeletionCollection.request?(Map.delete(request, "release"))
      else
        refute BranchDeletionCollection.request?(put_in(request, ["completion", "held"], false))
      end

      for field <- ~w(collection_sha256 completion_sha256 deletion_sha256) do
        refute BranchDeletionCollection.valid?(
                 Map.put(row["proof"], field, String.duplicate("0", 64))
               )
      end
    end
  end
end
