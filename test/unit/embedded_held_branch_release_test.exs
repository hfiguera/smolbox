defmodule SmolBox.Embedded.HeldBranchReleaseTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchReleaseTransition,
    Channel,
    HeldBranchReleaseRequest,
    Protocol,
    Request
  }

  alias SmolBox.Store.{Memory, NativeBranchReleaseContract}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-held-release-v1.json")
  @env_fixture Path.join(@fixtures, "branch-held-release-env-v1.json")
  @external_resource @fixture
  @external_resource @env_fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  test "wire authority comes from the original frozen store release without inventing another request" do
    {_, child, result, _} = NativeBranchReleaseContract.prepare(Memory, start_supervised!(Memory))
    wire = HeldBranchReleaseRequest.from_authority(child.branch.native_authority)
    assert HeldBranchReleaseRequest.valid?(wire)
    assert wire["request"] == child.branch.native_authority.release.request
    assert wire["source"] == child.branch.native_authority.release.source

    assert HeldBranchReleaseRequest.matches?(
             BranchReleaseTransition.to_wire(result.transition),
             wire
           )
  end

  defp operation(row, qualify),
    do: %{
      "operation" => if(qualify, do: "qualify_held_branch_release", else: "release_held_branch"),
      "request" => row["request"]
    }

  defp outcome(row, qualify),
    do: %{
      "result" => if(qualify, do: "held_branch_release_presence", else: "held_branch_released"),
      "transition" => row["transition"]
    }

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "shared explicit release proofs and requests retain original completion source and request authority" do
    for row <- @rows, qualify <- [false, true] do
      assert HeldBranchReleaseRequest.valid?(row["request"])
      assert HeldBranchReleaseRequest.matches?(row["transition"], row["request"])
      limit = if qualify, do: 30_000, else: 900_000
      assert Request.valid?(operation(row, qualify), limit, 2)
      refute Request.valid?(operation(row, qualify), limit + 1, 2)
      refute Request.valid?(operation(row, qualify), 1000, 1)
      assert Request.control?(operation(row, qualify)) == qualify
      assert Request.observation?(operation(row, qualify)) == qualify
      assert Request.reconciliation?(operation(row, qualify)) == qualify
      assert Request.receipt(operation(row, qualify)) == row["request"]["source"]
      assert Protocol.valid_outcome?(outcome(row, qualify), 2)
      refute Protocol.valid_outcome?(outcome(row, qualify), 1)
      refute Request.valid?(Map.put(operation(row, qualify), "quiesced", true), 1000, 2)

      assert HeldBranchReleaseRequest.approval(row["request"]) ==
               row["request"]["completion"]["publication"]["change"]["child_origin"]["intent"][
                 "approval"
               ]
    end
  end

  test "accepts the Rust release proof for a vertical tab and a literal Unicode escape" do
    [row | _] = @rows
    %{"env" => env, "chain_sha256" => digest} = Jason.decode!(File.read!(@env_fixture))
    assert env == [["MODE", "before\vafter"], ["TEXT", ~S(literal\u000B)]]

    request = put_in(row["request"], ~w(request env), env)

    proof =
      row["transition"]
      |> put_in(~w(change request env), env)
      |> put_in(~w(receipt material chain_sha256), digest)

    assert HeldBranchReleaseRequest.matches?(proof, request)

    assert Protocol.valid_outcome?(
             %{"result" => "held_branch_released", "transition" => proof},
             2
           )
  end

  test "valid shape substitutions cannot change completion identity original release request or namespace" do
    for row <- @rows do
      request = row["request"]

      for changed <- [
            put_in(request, ~w(request operation_id), "different-release"),
            put_in(request, ~w(completion identity_sha256), String.duplicate("0", 64))
          ] do
        assert HeldBranchReleaseRequest.valid?(changed)
        refute HeldBranchReleaseRequest.matches?(row["transition"], changed)
      end

      refute HeldBranchReleaseRequest.valid?(
               put_in(request, ~w(source owner_token), String.duplicate("0", 64))
             )

      refute HeldBranchReleaseRequest.valid?(Map.put(request, "path", "/foreign"))
      refute Protocol.valid_outcome?(%{"result" => "held_branch_release_presence"}, 2)

      refute Protocol.valid_outcome?(
               %{"result" => "held_branch_released", "transition" => nil},
               2
             )

      assert Protocol.valid_outcome?(
               %{"result" => "held_branch_release_presence", "transition" => nil},
               2
             )
    end
  end

  test "channel distinguishes dispatch qualification and missing results and rejects streams or a foreign platform" do
    for row <- @rows, qualify <- [false, true] do
      platform = HeldBranchReleaseRequest.platform(row["request"])
      hello = put_in(@hello, ~w(package platform), platform)

      assert {:ok, 1, channel} =
               Channel.register(Channel.new(hello), operation(row, qualify), 1024, 1)

      assert {:ok, channel, {1, :accepted}} =
               Channel.receive_message(channel, %{
                 "type" => "accepted",
                 "epoch" => channel.epoch,
                 "id" => 1,
                 "sequence" => 0
               })

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row, qualify)))

      assert :error =
               Channel.receive_message(channel, terminal(channel, outcome(row, not qualify)))

      missing = %{"result" => "held_branch_release_presence", "transition" => nil}
      reply = Channel.receive_message(channel, terminal(channel, missing))
      if qualify, do: assert(match?({:ok, _, _}, reply)), else: assert(reply == :error)

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

      foreign = %{
        Channel.new(hello)
        | platform: if(platform == "linux", do: "macos", else: "linux")
      }

      assert :error = Channel.register(foreign, operation(row, qualify), 0, 0)
    end
  end
end
