defmodule SmolBox.Embedded.GrowthWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Protocol, Request, SDKIdentity}

  defp proof do
    "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> hd()
  end

  defp operation(name \\ "expand_disks") do
    proof = proof()

    %{
      "operation" => name,
      "receipt" => proof["previous"],
      "operation_id" => proof["change"]["operation_id"],
      "request" => proof["change"]["request"],
      "previous" => %{"storage_gib" => 1, "overlay_gib" => 1}
    }
  end

  defp outcome do
    %{
      "result" => "grown",
      "transition" => proof(),
      "observation" => %{
        "state" => "stopped",
        "resources" => %{"cpus" => 1, "memory_mib" => 256, "storage_gib" => 2, "overlay_gib" => 1},
        "pid_identity" => nil
      }
    }
  end

  defp channel do
    receipt = proof()["previous"]

    Channel.new(%{
      "major" => 2,
      "minor" => 0,
      "epoch" => String.duplicate("ab", 16),
      "domain" => %{
        "target_id" => receipt["target_id"],
        "generation" => receipt["domain_generation"]
      }
    })
  end

  defp registered(name \\ "expand_disks") do
    channel = channel()

    request =
      if name == "qualify_growth",
        do: Map.put(operation(name), "quiesced", true),
        else: operation(name)

    assert {:ok, 1, channel} = Channel.register(channel, request, 0, 0)

    assert {:ok, channel, {1, :accepted}} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => channel.epoch,
               "id" => 1,
               "sequence" => 0
             })

    channel
  end

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "growth requests keep exact nullable targets, prior sizes and finite versioned budgets" do
    assert Request.valid?(operation(), 600_000, 2)
    refute Request.valid?(operation(), 600_001, 2)
    assert Request.valid?(operation("inspect_growth"), 30_000, 2)
    refute Request.valid?(operation("inspect_growth"), 30_001, 2)
    refute Request.valid?(operation(), 1000, 1)

    for invalid <- [
          put_in(operation()["request"]["storage_gib"], 1),
          put_in(operation()["request"]["storage_gib"], 65),
          put_in(operation()["previous"]["storage_gib"], 3),
          Map.delete(operation(), "operation_id"),
          put_in(operation()["request"], %{"storage_gib" => 2})
        ] do
      refute Request.valid?(invalid, 1000, 2)
    end
  end

  test "completion validates shared crypto proof and exact stopped geometry" do
    assert Protocol.valid_outcome?(outcome(), 2)
    refute Protocol.valid_outcome?(outcome(), 1)

    for invalid <- [
          put_in(
            outcome()["transition"]["receipt"]["material"]["chain_sha256"],
            String.duplicate("9", 64)
          ),
          put_in(outcome()["observation"]["resources"]["storage_gib"], 3),
          put_in(outcome()["observation"]["state"], "running"),
          Map.put(outcome(), "extra", 1)
        ] do
      refute Protocol.valid_outcome?(invalid, 2)
    end
  end

  test "channel binds the complete proof to its operation and never accepts bare observations" do
    channel = registered()

    assert :error =
             Channel.receive_message(
               channel,
               terminal(channel, %{
                 "result" => "observed",
                 "observation" => outcome()["observation"]
               })
             )

    wrong = put_in(outcome()["transition"]["change"]["operation_id"], "foreign")
    assert :error = Channel.receive_message(channel, terminal(channel, wrong))

    assert {:ok, retired, {1, {:terminal, _}}} =
             Channel.receive_message(channel, terminal(channel, outcome()))

    assert :error = Channel.receive_message(retired, terminal(retired, outcome()))
  end

  test "journal lookup cannot substitute for mutation completion or imply absence authority" do
    channel = registered("inspect_growth")
    assert :error = Channel.receive_message(channel, terminal(channel, outcome()))
    query = %{"result" => "growth_presence", "transition" => proof()}
    assert Protocol.valid_outcome?(query, 2)

    assert {:ok, _, {1, {:terminal, _}}} =
             Channel.receive_message(channel, terminal(channel, query))

    channel = registered("inspect_growth")

    assert {:ok, _, {1, {:terminal, _}}} =
             Channel.receive_message(
               channel,
               terminal(channel, %{"result" => "growth_presence", "transition" => nil})
             )
  end

  test "optional future capability order agrees with Rust while current approval cannot activate growth" do
    hello =
      "../../native/smolbox-protocol/fixtures/hello-v2-current.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("hello")

    refute "expand_disks" in Protocol.capabilities(hello["sdk"])
    current_sdk = hello["sdk"]
    sdk = put_in(current_sdk["feature_versions"]["disk_growth"], 1)
    assert SDKIdentity.valid?(sdk)
    refute SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"])

    assert Enum.take(Protocol.capabilities(sdk), 3) ==
             ~w(expand_disks inspect_growth qualify_growth)

    refute SDKIdentity.valid?(
             update_in(sdk["feature_versions"], &Map.delete(&1, "job_resources"))
           )
  end

  test "operator qualification requires explicit quiescence and its own bounded terminal kind" do
    request = Map.put(operation("qualify_growth"), "quiesced", true)
    assert Request.valid?(request, 30_000, 2)
    refute Request.observation?(request)
    refute Request.valid?(request, 30_001, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.valid?(Map.put(request, "quiesced", false), 1000, 2)
    refute Request.valid?(Map.delete(request, "quiesced"), 1000, 2)
    channel = registered("qualify_growth")
    assert :error = Channel.receive_message(channel, terminal(channel, outcome()))
    qualified = Map.put(outcome(), "result", "growth_qualified")
    assert Protocol.valid_outcome?(qualified, 2)
    refute Protocol.valid_outcome?(qualified, 1)

    assert {:ok, retired, {1, {:terminal, _}}} =
             Channel.receive_message(channel, terminal(channel, qualified))

    assert :error = Channel.receive_message(retired, terminal(retired, qualified))
    mutation = registered()
    assert :error = Channel.receive_message(mutation, terminal(mutation, qualified))
  end
end
