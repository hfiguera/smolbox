defmodule SmolBox.Embedded.BranchCredentialsTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, CreationFeatures, RegistryContract, Request}

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @release_file Path.join(@fixtures, "branch-held-release-v1.json")
  @external_resource @release_file
  @row @release_file |> File.read!() |> Jason.decode!() |> hd()
  @token "child-test-key"

  test "credential handoffs require protocol two, valid tokens and explicit feature negotiation" do
    requests = [
      %{"operation" => "start", "receipt" => @row["request"]["completion"]["child"]},
      %{"operation" => "release_held_branch", "request" => @row["request"]}
    ]

    hello =
      @fixtures
      |> Path.join("hello-v2.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("hello")
      |> Map.put("domain", %{
        "target_id" => @row["request"]["source"]["target_id"],
        "generation" => @row["request"]["source"]["domain_generation"]
      })

    for request <- requests do
      handoff = Map.put(request, "credential", @token)
      assert Request.valid?(handoff, 1000, 2)
      refute Request.valid?(handoff, 1000, 1)
      assert :error = Channel.register(Channel.new(hello), handoff, 0, 0)
      refute Request.valid?(%{handoff | "credential" => "line
break"}, 1000, 2)
      refute Request.valid?(%{handoff | "credential" => String.duplicate("a", 2049)}, 1000, 2)
      assert RegistryContract.sanitize(handoff) == request

      approved =
        update_in(hello, ~w(sdk feature_versions), &Map.put(&1, "branch_https_credentials", 1))

      assert {:ok, 1, channel} = Channel.register(Channel.new(approved), handoff, 0, 0)
      assert channel.pending[1].operation == request
    end
  end

  test "HTTPS creation is explicit and accepts a single approved host with neutral startup" do
    features = %{
      "branch_https" => true,
      "network" => %{"enabled" => true, "hosts" => ["api.example.test"], "cidrs" => []},
      "ports" => [],
      "workload" => nil
    }

    assert CreationFeatures.valid?(features)
    refute CreationFeatures.valid?(put_in(features, ~w(network hosts), []))
    refute CreationFeatures.valid?(put_in(features, ~w(network hosts), ["a.test", "b.test"]))
    refute CreationFeatures.valid?(put_in(features, ~w(network cidrs), ["192.0.2.0/24"]))
    refute CreationFeatures.valid?(%{features | "ports" => [%{"host" => 8080, "guest" => 80}]})
    refute CreationFeatures.valid?(%{features | "branch_https" => false})
  end
end
