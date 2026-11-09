defmodule SmolBox.Embedded.PartialBranchCleanupUnneededTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchBackingRelease, Channel, PartialBranchDisposal, Protocol, Request}
  alias SmolBox.Embedded.PartialBranchDisposalCleanup, as: Cleanup
  alias SmolBox.Embedded.PartialBranchDisposalCleanupUnneeded, as: Unneeded
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-cleanup-unneeded-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "resolve_partial_branch_cleanup", "request" => row["request"]}

  defp outcome(row), do: %{"result" => "partial_branch_cleanup_unneeded", "proof" => row["proof"]}

  defp channel(row, operation_name \\ "resolve_partial_branch_cleanup") do
    epoch = get_in(row, ~w(proof disposal publication change child_origin intent epoch))
    source = get_in(row, ~w(request disposal_request collection_request creation source))

    hello =
      @hello
      |> Map.put("epoch", epoch)
      |> put_in(~w(sdk feature_versions branches), 1)
      |> put_in(~w(sdk feature_versions partial_cleanup_resolution), 1)
      |> put_in(~w(package platform), row["platform"])
      |> put_in(~w(domain target_id), source["target_id"])
      |> put_in(~w(domain generation), source["domain_generation"])

    channel = %{Channel.new(hello) | unavailable: true}

    assert {:ok, 1, channel} =
             Channel.register(channel, %{operation(row) | "operation" => operation_name}, 1024, 1)

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
      assert {:ok, proof} = Unneeded.from_wire(row["proof"])
      assert Unneeded.valid?(proof) and Unneeded.matches?(proof, row["request"])
      assert Unneeded.to_wire(proof) == row["proof"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ row["request"]["request_sha256"]

      refute inspect(proof) =~
               get_in(row, ~w(proof disposal publication change child_origin intent epoch))

      assert :error = Unneeded.from_wire(proof)
      refute Unneeded.valid?(Map.put(proof, :extra, true))

      for invalid <- [nil, [], 1, "invalid", %{}] do
        refute Unneeded.valid?(invalid)
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
        refute Unneeded.valid?(Map.put(proof, "proof_sha256", Unneeded.proof_digest(proof)))
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
      proof = Map.put(proof, "proof_sha256", Unneeded.proof_digest(proof))
      assert Unneeded.valid?(proof)
      refute Unneeded.matches?(proof, row["request"])
      channel = channel(row)
      result = %{"result" => "partial_branch_cleanup_unneeded", "proof" => proof}
      assert :error = Channel.receive_message(channel, terminal(channel, result))
    end
  end

  test "unnecessary acknowledgement cannot replace actual removal proof or satisfy its old operation" do
    for row <- @rows do
      refute Cleanup.valid?(row["proof"])
      old = row["proof"]
      disposal = Map.put(old["disposal"], "completion", "resolved_absent")
      disposal = Map.put(disposal, "proof_sha256", PartialBranchDisposal.proof_digest(disposal))
      old = Map.put(old, "disposal", disposal)
      old = Map.put(old, "proof_sha256", Cleanup.proof_digest(old))
      assert Cleanup.valid?(old)
      refute Unneeded.valid?(old)
      current = channel(row)

      assert :error =
               Channel.receive_message(
                 current,
                 terminal(current, %{
                   "result" => "partial_branch_disposal_cleaned",
                   "proof" => old
                 })
               )

      removal = channel(row, "cleanup_partial_branch_disposal")
      assert :error = Channel.receive_message(removal, terminal(removal, outcome(row)))
    end
  end

  test "strict schema cannot grant path selection dependency retirement or backing release" do
    for row <- @rows do
      for key <- ~w(path pid completion backing_removed) do
        refute Cleanup.request?(Map.put(row["request"], key, true))
        assert :error = Unneeded.from_wire(Map.put(row["proof"], key, true))
        refute Request.valid?(Map.put(operation(row), key, true), 1000, 2)
      end

      refute Unneeded.valid?(row["proof"]["disposal"])
      refute PartialBranchDisposal.request?(row["request"])
      refute BranchBackingRelease.request?(row["request"])
      refute Protocol.valid_outcome?(Map.put(outcome(row), "extra", true), 2)

      refute Protocol.valid_outcome?(
               %{"result" => "partial_branch_cleanup_unneeded", "proof" => nil},
               2
             )

      channel = channel(row)
      wrong = put_in(channel.domain["generation"], String.duplicate("0", 32))
      assert :error = Channel.register(wrong, operation(row), 1024, 1)
    end
  end

  test "new opcode requires explicit optional feature and does not activate public package approval" do
    alias SmolBox.Embedded.SDKIdentity

    for row <- @rows do
      missing = %{channel(row) | partial_cleanup_resolution: false, pending: %{}, last_id: 0}
      assert :error = Channel.register(missing, operation(row), 1024, 1)
    end

    sdk = put_in(@hello, ~w(sdk feature_versions partial_cleanup_resolution), 1)["sdk"]
    refute SDKIdentity.valid?(sdk)
    sdk = put_in(sdk, ~w(feature_versions branches), 1)
    assert SDKIdentity.valid?(sdk)
    refute SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"], :linux)
  end
end
