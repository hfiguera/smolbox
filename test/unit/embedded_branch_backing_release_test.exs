defmodule SmolBox.Embedded.BranchBackingReleaseTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchBackingRelease, Channel, Protocol, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-backing-release-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "release_branch_backing", "request" => row["request"]}

  defp outcome(row), do: %{"result" => "branch_backing_released", "proof" => row["proof"]}

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared held initial and explicit release proofs validate canonical hashes and redact authority" do
    for row <- @rows do
      assert BranchBackingRelease.request?(row["request"])
      assert {:ok, proof} = BranchBackingRelease.from_wire(row["proof"])
      assert BranchBackingRelease.valid?(proof)
      assert BranchBackingRelease.to_wire(proof) == row["proof"]
      assert BranchBackingRelease.matches?(proof, row["request"])
      assert BranchBackingRelease.platform(row["request"]) == row["platform"]
      refute inspect(proof) =~ row["request"]["child"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
    end

    for malformed <- [nil, [], 1, "invalid", %{}] do
      refute BranchBackingRelease.request?(malformed)
      refute BranchBackingRelease.valid?(malformed)
      assert :error = BranchBackingRelease.from_wire(malformed)
    end
  end

  test "fenced accounting request has a finite budget exact keys and explicit host confirmation" do
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

      refute Protocol.valid_outcome?(%{"result" => "branch_backing_released", "proof" => nil}, 2)
      refute Protocol.valid_outcome?(%{"result" => "branch_backing_released"}, 2)
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
          BranchBackingRelease.request_digest(wrong["request"])
        )

      assert Request.valid?(wrong, 1000, 2)

      assert {:ok, _, mismatched} =
               Channel.register(%{channel | pending: %{}, last_id: 0}, wrong, 1024, 1)

      assert :error = Channel.receive_message(mismatched, terminal(mismatched, outcome(row)))
    end
  end

  test "platform domain proof digest root and history substitutions cannot acknowledge release" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | platform: row["platform"]}
      other = if row["platform"] == "macos", do: "linux", else: "macos"
      assert :error = Channel.register(%{channel | platform: other}, operation(row), 0, 0)

      crossed =
        put_in(operation(row), ~w(request child domain_generation), String.duplicate("e", 32))

      assert :error = Channel.register(channel, crossed, 0, 0)

      refute BranchBackingRelease.valid?(
               put_in(row["proof"], ~w(proof_sha256), String.duplicate("0", 64))
             )

      changed = put_in(row["request"], ~w(operation_id), "different-observation")
      refute BranchBackingRelease.request?(changed)
      changed = Map.put(changed, "request_sha256", BranchBackingRelease.request_digest(changed))
      assert BranchBackingRelease.request?(changed)
      refute BranchBackingRelease.matches?(row["proof"], changed)
      refute BranchBackingRelease.valid?(Map.put(row["proof"], "backing_removed", true))
    end
  end

  test "confirmation old heads request identity and exact native charge cannot be substituted" do
    for row <- @rows do
      request = row["request"]
      refute BranchBackingRelease.request?(%{request | "backing_removed" => false})

      for changed <- [
            %{request | "backing_removed" => false},
            %{request | "source" => request["completion"]["publication"]["previous"]},
            %{
              request
              | "operation_id" =>
                  get_in(
                    request,
                    ~w(completion publication change child_origin intent child operation_id)
                  )
            }
          ] do
        refute BranchBackingRelease.request?(
                 Map.put(changed, "request_sha256", BranchBackingRelease.request_digest(changed))
               )
      end

      refute BranchBackingRelease.valid?(Map.update!(row["proof"], "native_bytes", &(&1 + 1)))

      refute BranchBackingRelease.valid?(
               Map.put(row["proof"], "native_bytes", :erlang.float(row["proof"]["native_bytes"]))
             )

      assert {:ok, proof} = BranchBackingRelease.from_wire(row["proof"])
      assert :error = BranchBackingRelease.from_wire(proof)
      refute BranchBackingRelease.valid?(Map.put(proof, :foreign, true))
    end
  end
end
