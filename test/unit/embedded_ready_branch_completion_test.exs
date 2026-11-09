defmodule SmolBox.EmbeddedReadyBranchCompletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Request}
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @rows @fixtures |> Path.join("branch-creation-v1.json") |> File.read!() |> Jason.decode!()
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  test "explicit recovery is fenced bounded protocol-two control and never read-only observation" do
    for row <- @rows do
      request = %{
        "operation" => "resolve_ready_branch_completion",
        "request" => row["request"],
        "quiesced" => true
      }

      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      refute Request.valid?(request, 1, 1)
      assert Request.control?(request) and Request.reconciliation?(request)
      refute Request.observation?(request)
      assert Request.receipt(request) == row["request"]["source"]

      for invalid <- [
            Map.delete(request, "quiesced"),
            %{request | "quiesced" => false},
            Map.put(request, "path", "/foreign")
          ],
          do: refute(Request.valid?(invalid, 1, 2))
    end
  end

  test "channel correlates exact completion original epoch platform and zero-output terminal" do
    for row <- @rows do
      request = %{
        "operation" => "resolve_ready_branch_completion",
        "request" => row["request"],
        "quiesced" => true
      }

      hello =
        Map.put(
          @hello,
          "epoch",
          get_in(row, ~w(completion publication change child_origin intent epoch))
        )

      {:ok, 1, channel} = Channel.register(Channel.new(hello), request, 1024, 1)

      {:ok, channel, _} =
        Channel.receive_message(channel, %{
          "type" => "accepted",
          "epoch" => channel.epoch,
          "id" => 1,
          "sequence" => 0
        })

      outcome = %{"result" => "branch_completion_presence", "completion" => row["completion"]}

      terminal = %{
        "type" => "terminal",
        "epoch" => channel.epoch,
        "id" => 1,
        "sequence" => 1,
        "outcome" => outcome
      }

      assert {:ok, _, _} = Channel.receive_message(channel, terminal)

      assert {:ok, _, _} =
               Channel.receive_message(channel, put_in(terminal, ~w(outcome completion), nil))

      assert :error = Channel.receive_message(%{channel | platform: "linux"}, terminal)
      crossed = %{channel | epoch: String.duplicate("e", 32)}
      assert :error = Channel.receive_message(crossed, %{terminal | "epoch" => crossed.epoch})

      for stream <- ~w(stdout stderr file checkpoint log terminal) do
        assert :error =
                 Channel.receive_message(channel, %{
                   "type" => "event",
                   "epoch" => channel.epoch,
                   "id" => 1,
                   "sequence" => 1,
                   "event" => %{"stream" => stream, "data_base64" => Base.encode64("extra")}
                 })
      end
    end
  end
end
