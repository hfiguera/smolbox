defmodule SmolBox.Embedded.BranchCreationTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchCompletion, BranchRequest, Channel, Protocol, Request}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-creation-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  test "held and initially released native proofs retain exact Rust hash algebra and redact inspection" do
    for row <- @rows do
      assert BranchRequest.valid?(row["request"])
      assert {:ok, proof} = BranchCompletion.from_wire(row["completion"])
      assert BranchCompletion.valid?(proof)
      assert BranchCompletion.to_wire(proof) == row["completion"]
      assert BranchCompletion.matches?(row["completion"], row["request"])
      refute inspect(proof) =~ row["request"]["source"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row, false), 2)
      refute Protocol.valid_outcome?(outcome(row, false), 1)
    end
  end

  test "request validation fixes mode policy independent identity and bounded budgets before dispatch" do
    for row <- @rows, lookup <- [false, true] do
      request = operation(row, lookup)
      limit = if lookup, do: 30_000, else: 900_000
      assert Request.valid?(request, limit, 2)
      refute Request.valid?(request, limit + 1, 2)
      refute Request.valid?(request, 1000, 1)
      assert Request.observation?(request) == lookup
      assert Request.control?(request) == lookup
      assert Request.reconciliation?(request) == lookup

      for key <- ~w(path pid policy quiesced),
          do: refute(Request.valid?(Map.put(request, key, true), 1000, 2))

      refute BranchRequest.valid?(put_in(row["request"], ["source", "material"], nil))

      for key <- ~w(name owner_token incarnation) do
        invalid = put_in(row["request"], ["child", key], row["request"]["source"][key])
        refute BranchRequest.valid?(invalid)
      end

      if row["request"]["child"]["hold"] do
        refute BranchRequest.valid?(Map.put(row["request"], "initial_release", nil))
      else
        refute BranchRequest.valid?(Map.delete(row["request"], "initial_release"))
      end
    end

    for malformed <- [nil, [], 1, "invalid", %{}],
        do: refute(BranchRequest.valid?(malformed))
  end

  test "valid-shape proof substitutions cannot replace source child policy release or material evidence" do
    for row <- @rows do
      for path <- [
            ~w(publication receipt material chain_sha256),
            ~w(publication change child material chain_sha256),
            ~w(publication change child_origin intent request_sha256),
            ~w(publication change child_origin raw_child_sha256),
            ~w(child owner_token)
          ] do
        value = put_in(row["completion"], path, String.duplicate("0", 64))
        assert :error = BranchCompletion.from_wire(value)
      end

      for path <- [
            ~w(approval resources disk_gb),
            ~w(child operation_id),
            ~w(source material_sha256)
          ] do
        value = get_in(row["request"], path)
        changed = if is_integer(value), do: value + 1, else: "different"
        refute BranchCompletion.matches?(row["completion"], put_in(row["request"], path, changed))
      end

      if row["request"]["initial_release"] do
        value =
          put_in(
            row["completion"],
            ~w(release change activation_token),
            String.duplicate("0", 64)
          )

        assert :error = BranchCompletion.from_wire(value)
      end

      for malformed <- [nil, [], 1, "invalid", %{}],
          do: assert(:error = BranchCompletion.from_wire(malformed))
    end
  end

  test "channel binds both result kinds to exact requests domains and platform without accepting streams" do
    for row <- @rows, lookup <- [false, true] do
      request = operation(row, lookup)
      {:ok, 1, channel} = Channel.register(Channel.new(@hello), request, 1024, 1)
      accepted = %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
      {:ok, channel, {1, :accepted}} = Channel.receive_message(channel, accepted)
      reply = terminal(channel, outcome(row, lookup))
      assert {:ok, _, {1, {:terminal, _}}} = Channel.receive_message(channel, reply)

      assert :error =
               Channel.receive_message(channel, terminal(channel, outcome(row, not lookup)))

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

      crossed = put_in(request, ~w(request source domain_generation), String.duplicate("e", 32))
      assert :error = Channel.register(Channel.new(@hello), crossed, 1024, 1)
      assert :error = Channel.receive_message(%{channel | platform: "linux"}, reply)

      missing = %{"result" => "branch_completion_presence", "completion" => nil}
      result = Channel.receive_message(channel, terminal(channel, missing))
      if lookup, do: assert(match?({:ok, _, _}, result)), else: assert(result == :error)
    end
  end

  test "helper catalog forwarding is feature gated and freezes the full approval including host overhead" do
    alias SmolBox.Embedded.{Config, Launch, SDKIdentity}
    [row | _] = @rows
    approval = row["request"]["approval"]

    resources =
      Map.new(approval["resources"], fn {key, value} -> {String.to_existing_atom(key), value} end)

    {:ok, policy} = SmolBox.BranchPolicy.new(id: approval["id"], resources: resources)
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)

    config = %{
      config
      | branch_policies: [policy],
        profiles:
          Enum.map(config.profiles, &%{&1 | host_overhead_mb: approval["host_overhead_mb"]}),
        allocation_floor: %{
          config.allocation_floor
          | host_overhead_mb: approval["host_overhead_mb"]
        }
    }

    assert :ok = Config.validate(config)
    assert BranchRequest.approvals(config) == [approval]
    refute Map.has_key?(Launch.helper_config(config), "approved_branches")
    package = Map.put(config.package_identity, "engine_version", "0.2.0")
    sdk = SDKIdentity.implemented("1.22.0", package["smolvm_revision"])
    sdk = put_in(sdk, ["feature_versions", "branches"], 1)
    future = %{config | package_identity: package, sdk_identity: sdk}
    assert {:error, _} = Config.validate(future)
    assert Launch.helper_config(future)["approved_branches"] == [approval]

    refute Map.has_key?(
             Launch.helper_config(%{future | branch_policies: []}),
             "approved_branches"
           )

    [profile] = future.profiles
    second = %{profile | id: "other-overhead", host_overhead_mb: 256}
    varied = %{future | profiles: [profile, second]}
    assert BranchRequest.approvals(varied) == [approval, %{approval | "host_overhead_mb" => 256}]
    assert Launch.helper_config(varied)["approved_branches"] == BranchRequest.approvals(varied)

    assert BranchRequest.approvals(%{varied | allocation_floor: config.allocation_floor}) ==
             BranchRequest.approvals(varied)

    maximum = %{
      future
      | profiles:
          for(index <- 0..31, do: %{profile | id: "p-#{index}", host_overhead_mb: 128 + index}),
        branch_policies: for(index <- 0..31, do: %{policy | id: "policy-#{index}"})
    }

    catalog = Launch.helper_config(maximum)["approved_branches"]
    assert Enum.count_until(catalog, 1025) == 1024
    assert byte_size(Jason.encode!(catalog)) > 65_536
    assert byte_size(Jason.encode!(Launch.helper_config(maximum))) < 524_288
  end

  defp operation(row, lookup),
    do: %{
      "operation" => if(lookup, do: "inspect_branch_completion", else: "create_branch"),
      "request" => row["request"]
    }

  defp outcome(row, lookup),
    do: %{
      "result" => if(lookup, do: "branch_completion_presence", else: "branch_created"),
      "completion" => row["completion"]
    }

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }
end
