defmodule SmolBox.EmbeddedCollectedBranchPublicationTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchCompletion, BranchPublication, Channel, Protocol, Request}

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-creation-v1.json")
  @external_resource @fixture
  @rows @fixture |> File.read!() |> Jason.decode!()
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{
      "operation" => "publish_collected_branch_material",
      "request" => row["request"],
      "quiesced" => true
    }

  defp outcome(row),
    do: %{
      "result" => "collected_branch_material_published",
      "publication" => row["completion"]["publication"]
    }

  defp accepted(row, operation \\ nil) do
    hello =
      Map.put(
        @hello,
        "epoch",
        get_in(row, ~w(completion publication change child_origin intent epoch))
      )

    channel = %{Channel.new(hello) | unavailable: true}
    {:ok, 1, channel} = Channel.register(channel, operation || operation(row), 1024, 1)

    {:ok, channel, {1, :accepted}} =
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

  test "publication continuation is a fenced finite protocol-two control with exact fields" do
    for row <- @rows do
      request = operation(row)
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1, 1)
      assert Request.control?(request) and Request.reconciliation?(request)
      refute Request.observation?(request)
      assert Request.receipt(request) == row["request"]["source"]

      for invalid <- [
            Map.delete(request, "quiesced"),
            Map.put(request, "quiesced", false),
            Map.put(request, "quiesced", nil),
            Map.put(request, "path", "/foreign")
          ] do
        refute Request.valid?(invalid, 1, 2)
        refute Request.control?(invalid)
      end
    end
  end

  test "canonical material projection preserves typed bytes and never attests activation" do
    for row <- @rows do
      publication = row["completion"]["publication"]
      assert {:ok, typed} = BranchPublication.from_wire(publication)
      assert BranchPublication.matches?(publication, row["request"])
      assert BranchPublication.matches?(typed, row["request"])
      assert BranchPublication.to_wire(typed) == publication
      refute inspect(typed) =~ publication["previous"]["owner_token"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)

      if row["request"]["initial_release"] do
        changed =
          put_in(row["request"], ~w(initial_release operation_id), "different-initial-release")

        assert BranchPublication.matches?(publication, changed)
        refute BranchCompletion.matches?(row["completion"], changed)
      end

      for bad <- [nil, %{}, [], 1, "invalid"] do
        refute BranchPublication.matches?(bad, row["request"])
        refute BranchPublication.matches?(publication, bad)
      end
    end
  end

  test "quarantined channel binds source child approval epoch platform and material-only result" do
    for row <- @rows do
      channel = accepted(row)
      message = terminal(channel, outcome(row))
      assert {:ok, ^message} = Protocol.decode(Jason.encode!(message), 2)
      assert {:ok, _, {1, {:terminal, _}}} = Channel.receive_message(channel, message)
      assert :error = Channel.receive_message(%{channel | platform: "linux"}, message)
      crossed = %{channel | epoch: String.duplicate("e", 32)}
      assert :error = Channel.receive_message(crossed, %{message | "epoch" => crossed.epoch})

      for changed <- [
            put_in(operation(row), ~w(request child name), "different-child"),
            update_in(operation(row), ~w(request approval resources disk_gb), &(&1 + 1))
          ] do
        assert Request.valid?(changed, 1, 2)
        other = accepted(row, changed)
        assert :error = Channel.receive_message(other, terminal(other, outcome(row)))
      end

      for result <- [
            %{"result" => "branch_created", "completion" => row["completion"]},
            %{"result" => "branch_completion_presence", "completion" => nil},
            %{"result" => "qualified"}
          ] do
        assert :error = Channel.receive_message(channel, terminal(channel, result))
      end

      pending = Map.update!(channel.pending, 1, &%{&1 | output_bytes: 1})
      assert :error = Channel.receive_message(%{channel | pending: pending}, message)

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

      wrong_domain =
        put_in(operation(row), ~w(request source domain_generation), String.duplicate("f", 32))

      assert :error = Channel.register(Channel.new(@hello), wrong_domain, 1024, 1)
    end
  end

  test "publication outcome rejects absent null substituted and extra proof fields" do
    for row <- @rows do
      for invalid <- [
            Map.delete(outcome(row), "publication"),
            Map.put(outcome(row), "publication", nil),
            Map.put(outcome(row), "publication", row["completion"]),
            Map.put(outcome(row), "ready", true),
            put_in(outcome(row), ~w(publication change platform), "foreign")
          ] do
        refute Protocol.valid_outcome?(invalid, 2)
        channel = accepted(row)
        assert :error = Channel.receive_message(channel, terminal(channel, invalid))
      end
    end
  end
end
