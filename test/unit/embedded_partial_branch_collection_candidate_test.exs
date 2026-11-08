defmodule SmolBox.Embedded.PartialBranchCollectionCandidateTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    Channel,
    PartialBranchCollection,
    PartialBranchCollectionCandidate,
    Protocol,
    Request,
    SDKIdentity
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "partial-branch-collection-candidate-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{"operation" => "inspect_partial_branch_collection", "request" => row["request"]}

  defp outcome(row),
    do: %{"result" => "partial_branch_collection_candidate", "candidate" => row["candidate"]}

  defp channel(row, enabled \\ true) do
    source = row["request"]["creation"]["source"]

    hello =
      @hello
      |> Map.put("epoch", row["candidate"]["epoch"])
      |> put_in(~w(sdk feature_versions branches), 1)
      |> put_in(~w(package platform), row["platform"])
      |> put_in(~w(domain target_id), source["target_id"])
      |> put_in(~w(domain generation), source["domain_generation"])

    hello =
      if enabled,
        do: put_in(hello, ~w(sdk feature_versions partial_collection_preflight), 1),
        else: hello

    %{Channel.new(hello) | unavailable: true}
  end

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  defp accepted(row) do
    channel = channel(row)
    assert {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

    assert {:ok, channel, {1, :accepted}} =
             Channel.receive_message(
               channel,
               %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
             )

    channel
  end

  test "canonical readers retain exact prospective request and no collection authority" do
    for row <- @rows do
      assert {:ok, candidate} = PartialBranchCollectionCandidate.from_wire(row["candidate"])
      assert PartialBranchCollectionCandidate.matches?(candidate, row["request"])
      assert PartialBranchCollectionCandidate.to_wire(candidate) == row["candidate"]
      refute PartialBranchCollection.valid?(row["candidate"])
      refute inspect(candidate) =~ row["candidate"]["request_sha256"]
      assert :error = PartialBranchCollectionCandidate.from_wire(candidate)
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      assert Request.valid?(operation(row), 30_000, 2)
      refute Request.valid?(operation(row), 30_001, 2)
      refute Request.valid?(operation(row), 1000, 1)
      assert Request.control?(operation(row)) and Request.reconciliation?(operation(row))
      assert Request.receipt(operation(row)) == row["request"]["creation"]["source"]

      for key <- ~w(pid path proof collected owner_token) do
        refute PartialBranchCollectionCandidate.valid?(Map.put(row["candidate"], key, true))
      end
    end

    for value <- [nil, [], 1, "invalid", %{}] do
      refute PartialBranchCollectionCandidate.valid?(value)
    end
  end

  test "unnegotiated or crossed request epoch and platform cannot select admission" do
    for row <- @rows do
      assert :error = Channel.register(channel(row, false), operation(row), 1024, 1)
      original = accepted(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(original, terminal(original, outcome(row)))

      for invalid <- [
            put_in(outcome(row), ~w(candidate epoch), String.duplicate("f", 32)),
            put_in(outcome(row), ~w(candidate request_sha256), String.duplicate("0", 64)),
            put_in(outcome(row), ~w(candidate creation_sha256), String.duplicate("0", 64)),
            put_in(
              outcome(row),
              ~w(candidate platform),
              if(row["platform"] == "linux", do: "macos", else: "linux")
            )
          ] do
        assert :error = Channel.receive_message(original, terminal(original, invalid))
      end

      assert :error =
               Channel.receive_message(original, %{
                 "type" => "output",
                 "epoch" => original.epoch,
                 "id" => 1,
                 "sequence" => 1,
                 "stream" => "stdout",
                 "data" => Base.encode64("unexpected")
               })
    end
  end

  test "feature is explicit dependent on branches and platform approval" do
    sdk =
      @hello["sdk"]
      |> put_in(~w(feature_versions branches), 1)
      |> put_in(~w(feature_versions partial_collection_preflight), 1)

    assert SDKIdentity.valid?(sdk)
    assert SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"], :linux)
    assert SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"], :macos)
    refute SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"])
    refute SDKIdentity.valid?(put_in(sdk, ~w(feature_versions partial_collection_preflight), 2))
    refute SDKIdentity.valid?(update_in(sdk, ["feature_versions"], &Map.delete(&1, "branches")))
  end
end
