defmodule SmolBox.Embedded.HeldBranchDeletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchDeletionResolution, Channel, Protocol, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "held-branch-deletion-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "resolve_held_branch_deletion", "request" => row["request"]}

  defp outcome(row), do: %{"result" => "held_branch_deletion_resolved", "proof" => row["proof"]}

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared held deletion proofs validate canonical hashes and redact authority" do
    for row <- @rows do
      assert BranchDeletionResolution.request?(row["request"])
      assert {:ok, proof} = BranchDeletionResolution.from_wire(row["proof"])
      assert BranchDeletionResolution.valid?(proof)
      assert BranchDeletionResolution.to_wire(proof) == row["proof"]
      assert BranchDeletionResolution.matches?(proof, row["request"])
      assert BranchDeletionResolution.platform(row["request"]) == row["platform"]
      refute inspect(proof) =~ row["request"]["child"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
    end

    for malformed <- [nil, [], 1, "invalid", %{}] do
      refute BranchDeletionResolution.request?(malformed)
      refute BranchDeletionResolution.valid?(malformed)
      assert :error = BranchDeletionResolution.from_wire(malformed)
    end
  end

  test "fenced absence resolution has a finite budget exact keys and no SDK deletion authority" do
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
               %{"result" => "held_branch_deletion_resolved", "proof" => nil},
               2
             )

      refute Protocol.valid_outcome?(%{"result" => "held_branch_deletion_resolved"}, 2)
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
          BranchDeletionResolution.request_digest(wrong["request"])
        )

      assert Request.valid?(wrong, 1000, 2)

      assert {:ok, _, mismatched} =
               Channel.register(%{channel | pending: %{}, last_id: 0}, wrong, 1024, 1)

      assert :error = Channel.receive_message(mismatched, terminal(mismatched, outcome(row)))
    end
  end

  test "platform domain proof digest root and history substitutions cannot assert absence" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | platform: row["platform"]}
      other = if row["platform"] == "macos", do: "linux", else: "macos"
      assert :error = Channel.register(%{channel | platform: other}, operation(row), 0, 0)

      crossed =
        put_in(operation(row), ~w(request child domain_generation), String.duplicate("e", 32))

      assert :error = Channel.register(channel, crossed, 0, 0)

      refute BranchDeletionResolution.valid?(
               put_in(row["proof"], ~w(proof_sha256), String.duplicate("0", 64))
             )

      changed = put_in(row["request"], ~w(operation_id), "different-observation")
      refute BranchDeletionResolution.request?(changed)

      changed =
        Map.put(changed, "request_sha256", BranchDeletionResolution.request_digest(changed))

      assert BranchDeletionResolution.request?(changed)
      refute BranchDeletionResolution.matches?(row["proof"], changed)
      refute BranchDeletionResolution.valid?(Map.put(row["proof"], "backing_removed", true))
    end
  end

  test "released roots initialization variants reused creation identity and unsafe fields reject" do
    branches =
      @fixtures |> Path.join("branch-child-absence-v1.json") |> File.read!() |> Jason.decode!()

    for row <- branches, row["mode"] != "held" do
      base = hd(@rows)["request"]

      changed = %{
        base
        | "completion" => row["request"]["completion"],
          "child" => row["request"]["child"]
      }

      changed =
        Map.put(changed, "request_sha256", BranchDeletionResolution.request_digest(changed))

      refute BranchDeletionResolution.request?(changed)
    end

    for row <- @rows do
      request = row["request"]

      reused =
        Map.put(
          request,
          "operation_id",
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          )
        )

      refute BranchDeletionResolution.request?(
               Map.put(reused, "request_sha256", BranchDeletionResolution.request_digest(reused))
             )

      assert {:ok, proof} = BranchDeletionResolution.from_wire(row["proof"])
      assert :error = BranchDeletionResolution.from_wire(proof)
      refute BranchDeletionResolution.valid?(Map.put(proof, :unexpected, true))

      refute BranchDeletionResolution.valid?(
               put_in(row["proof"], ~w(deletion_sha256), String.duplicate("0", 64))
             )

      refute BranchDeletionResolution.request?(Map.put(request, "delete", true))
    end
  end
end
