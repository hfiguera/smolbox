defmodule SmolBox.Embedded.PartialBranchDisposalCleanupTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchBackingRelease, Channel, PartialBranchDisposal, Protocol, Request}
  alias SmolBox.Embedded.PartialBranchDisposalCleanup, as: Cleanup
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-disposal-cleanup-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "cleanup_partial_branch_disposal", "request" => row["request"]}

  defp outcome(row), do: %{"result" => "partial_branch_disposal_cleaned", "proof" => row["proof"]}

  defp channel(row) do
    epoch = get_in(row, ~w(proof disposal publication change child_origin intent epoch))
    source = get_in(row, ~w(request disposal_request collection_request creation source))

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

  defp terminal(channel, result),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => result
    }

  test "synthetic readers preserve exact original disposal and optional release on both platforms" do
    for row <- @rows do
      assert Cleanup.request?(row["request"])
      assert {:ok, proof} = Cleanup.from_wire(row["proof"])
      assert Cleanup.valid?(proof) and Cleanup.matches?(proof, row["request"])
      assert Cleanup.to_wire(proof) == row["proof"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ row["request"]["request_sha256"]

      refute inspect(proof) =~
               get_in(row, ~w(proof disposal publication change child_origin intent epoch))

      assert :error = Cleanup.from_wire(proof)
      refute Cleanup.valid?(Map.put(proof, :extra, true))

      for invalid <- [nil, [], 1, "invalid", %{}] do
        refute Cleanup.valid?(invalid)
        refute Cleanup.request?(invalid)
      end
    end
  end

  test "only protocol two exact fenced requests use reserved control admission and the original source" do
    for row <- @rows do
      op = operation(row)
      assert Request.valid?(op, 30_000, 2)
      refute Request.valid?(op, 30_001, 2)
      refute Request.valid?(op, 1000, 1)
      assert Request.control?(op) and Request.reconciliation?(op)
      refute Request.observation?(op)

      assert Request.receipt(op) ==
               get_in(row, ~w(request disposal_request collection_request creation source))

      assert Cleanup.approval(row["request"]) ==
               get_in(row, ~w(request disposal_request collection_request creation approval))

      request = Map.put(row["request"], "quiesced", false)
      request = Map.put(request, "request_sha256", Cleanup.request_digest(request))
      refute Cleanup.request?(request)
      refute Request.control?(%{op | "request" => request})
    end
  end

  test "cleanup rejects all prior action IDs even when their digests are recomputed" do
    for row <- @rows do
      request = row["request"]

      for id <- [
            get_in(request, ~w(disposal_request operation_id)),
            get_in(request, ~w(disposal_request collection_request operation_id)),
            get_in(request, ~w(disposal_request collection_request creation child operation_id)),
            get_in(
              request,
              ~w(disposal_request collection_request creation initial_release operation_id)
            )
          ],
          id != nil do
        changed = Map.put(request, "operation_id", id)

        refute Cleanup.request?(
                 Map.put(changed, "request_sha256", Cleanup.request_digest(changed))
               )
      end

      release = get_in(row, ~w(proof disposal release))

      if release != nil do
        request =
          Map.put(request, "operation_id", get_in(release, ~w(change request operation_id)))

        request = Map.put(request, "request_sha256", Cleanup.request_digest(request))
        proof = %{row["proof"] | "request" => request}
        refute Cleanup.valid?(Map.put(proof, "proof_sha256", Cleanup.proof_digest(proof)))
      end
    end
  end

  test "required terminal has zero output exact platform and original epoch during quarantine" do
    for row <- @rows do
      channel = channel(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      wrong = %{channel | platform: if(row["platform"] == "macos", do: "linux", else: "macos")}
      assert :error = Channel.receive_message(wrong, terminal(wrong, outcome(row)))
      wrong = %{channel | epoch: String.duplicate("0", 32)}
      assert :error = Channel.receive_message(wrong, terminal(wrong, outcome(row)))

      for result <- [
            %{"result" => "qualified"},
            %{"result" => "partial_branch_disposed", "proof" => row["proof"]["disposal"]}
          ] do
        assert :error = Channel.receive_message(channel, terminal(channel, result))
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
    end
  end

  test "a separately valid rehashed acknowledgement cannot satisfy an earlier cleanup request" do
    for row <- @rows do
      request = Map.put(row["request"], "operation_id", "different-cleanup")
      request = Map.put(request, "request_sha256", Cleanup.request_digest(request))
      proof = Map.put(row["proof"], "request", request)
      proof = Map.put(proof, "proof_sha256", Cleanup.proof_digest(proof))
      assert Cleanup.valid?(proof)
      refute Cleanup.matches?(proof, row["request"])
      channel = channel(row)
      result = %{"result" => "partial_branch_disposal_cleaned", "proof" => proof}
      assert :error = Channel.receive_message(channel, terminal(channel, result))
    end
  end

  test "SDK deletion provenance cannot be rehashed into a cleanup acknowledgement" do
    for row <- @rows do
      disposal = Map.put(row["proof"]["disposal"], "completion", "deleted")
      disposal = Map.put(disposal, "proof_sha256", PartialBranchDisposal.proof_digest(disposal))
      assert PartialBranchDisposal.valid?(disposal)
      proof = Map.put(row["proof"], "disposal", disposal)
      proof = Map.put(proof, "proof_sha256", Cleanup.proof_digest(proof))
      refute Cleanup.valid?(proof)
    end
  end

  test "strict schema cannot grant path selection dependency retirement or backing release" do
    for row <- @rows do
      for key <- ~w(path pid completion backing_removed) do
        refute Cleanup.request?(Map.put(row["request"], key, true))
        assert :error = Cleanup.from_wire(Map.put(row["proof"], key, true))
        refute Request.valid?(Map.put(operation(row), key, true), 1000, 2)
      end

      refute Cleanup.valid?(row["proof"]["disposal"])
      refute PartialBranchDisposal.request?(row["request"])
      refute BranchBackingRelease.request?(row["request"])
      refute Protocol.valid_outcome?(Map.put(outcome(row), "extra", true), 2)

      refute Protocol.valid_outcome?(
               %{"result" => "partial_branch_disposal_cleaned", "proof" => nil},
               2
             )

      channel = channel(row)
      wrong = put_in(channel.domain["generation"], String.duplicate("0", 32))
      assert :error = Channel.register(wrong, operation(row), 1024, 1)
    end
  end
end
