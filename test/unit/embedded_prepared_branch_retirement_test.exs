defmodule SmolBox.Embedded.PreparedBranchRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Protocol, Request}
  alias SmolBox.Embedded.PreparedBranchRetirement, as: Retirement
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "prepared-branch-retirement-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  defp operation(row), do: %{"operation" => "retire_prepared_branch", "request" => row["request"]}
  defp outcome(row), do: %{"result" => "prepared_branch_retired", "proof" => row["proof"]}

  defp terminal(channel, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  defp digest(request), do: Map.put(request, "request_sha256", Retirement.request_digest(request))
  defp proof_digest(proof), do: Map.put(proof, "proof_sha256", Retirement.proof_digest(proof))

  test "shared fixtures bind a protected pre-entry declaration and independent host correlation" do
    for row <- @rows do
      assert Retirement.request?(row["request"])
      assert {:ok, proof} = Retirement.from_wire(row["proof"])
      assert Retirement.valid?(proof)
      assert Retirement.to_wire(proof) == row["proof"]
      assert Retirement.matches?(proof, row["request"])
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ get_in(row, ~w(request creation child owner_token))
      refute inspect(proof) =~ get_in(row, ~w(proof retirement intent epoch))
      assert :error = Retirement.from_wire(proof)
      refute Retirement.valid?(Map.put(proof, :extra, true))
    end
  end

  test "requests require fencing exact keys source receipt creation mode and finite budget" do
    for row <- @rows do
      operation = operation(row)
      assert Request.valid?(operation, 30_000, 2)
      refute Request.valid?(operation, 30_001, 2)
      refute Request.valid?(operation, 1000, 1)
      assert Request.receipt(operation) == row["request"]["creation"]["source"]
      assert Request.control?(operation) and Request.reconciliation?(operation)
      refute Request.observation?(operation)
      refute Retirement.request?(digest(Map.put(row["request"], "quiesced", false)))

      refute Retirement.request?(
               digest(put_in(row["request"], ~w(creation source material), nil))
             )

      wrong =
        if row["request"]["creation"]["child"]["hold"],
          do:
            put_in(row["request"], ~w(creation initial_release), %{
              "operation_id" => "unused",
              "request_sha256" => String.duplicate("d", 64)
            }),
          else: update_in(row["request"], ["creation"], &Map.delete(&1, "initial_release"))

      refute Retirement.request?(digest(wrong))

      for key <- ~w(path pid native_digest backing_removed) do
        refute Retirement.request?(Map.put(row["request"], key, true))
        refute Request.valid?(Map.put(operation, key, true), 1000, 2)
      end
    end
  end

  test "valid outer rebound hashes cannot replace original native source child or approval" do
    for row <- @rows,
        {path, value} <- [
          {~w(creation source domain_generation), String.duplicate("e", 32)},
          {~w(creation child name), "different-child"},
          {~w(creation approval id), "different-policy"}
        ] do
      changed = row["request"] |> put_in(path, value) |> digest()
      assert Retirement.request?(changed)

      proof =
        row["proof"] |> Map.put("request_sha256", changed["request_sha256"]) |> proof_digest()

      assert Retirement.valid?(proof)
      refute Retirement.matches?(proof, changed)
    end

    for row <- @rows do
      crossed =
        row["proof"]
        |> put_in(~w(retirement proof_sha256), String.duplicate("0", 64))
        |> proof_digest()

      refute Retirement.valid?(crossed)
      refute Retirement.valid?(row["proof"]["retirement"])
    end
  end

  test "channel correlates only the exact request accepts no stream and stays available for control" do
    for row <- @rows do
      channel = %{Channel.new(@hello) | unavailable: true}
      assert {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

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

      for stream <- ~w(stdout stderr file checkpoint terminal log) do
        assert :error =
                 Channel.receive_message(channel, %{
                   "type" => "event",
                   "epoch" => channel.epoch,
                   "id" => 1,
                   "sequence" => 1,
                   "event" => %{"stream" => stream, "data_base64" => Base.encode64("extra")}
                 })
      end

      wrong = row["request"] |> put_in(~w(creation approval id), "different-policy") |> digest()
      assert Retirement.request?(wrong)

      assert {:ok, _, mismatch} =
               Channel.register(
                 %{channel | pending: %{}, last_id: 0},
                 %{"operation" => "retire_prepared_branch", "request" => wrong},
                 0,
                 0
               )

      assert :error = Channel.receive_message(mismatch, terminal(mismatch, outcome(row)))
      domain = %{channel.domain | "generation" => String.duplicate("0", 32)}

      assert :error =
               Channel.register(
                 %{channel | domain: domain, pending: %{}, last_id: 0},
                 operation(row),
                 0,
                 0
               )
    end
  end

  test "missing nullable bare extra or malformed evidence cannot assert retirement" do
    for value <- [nil, [], 1, "invalid", %{}] do
      refute Retirement.request?(value)
      refute Retirement.valid?(value)
      assert :error = Retirement.from_wire(value)
      refute Retirement.matches?(value, value)
    end

    for row <- @rows do
      refute Protocol.valid_outcome?(Map.delete(outcome(row), "proof"), 2)
      refute Protocol.valid_outcome?(Map.put(outcome(row), "proof", nil), 2)

      refute Protocol.valid_outcome?(
               Map.put(outcome(row), "proof", row["proof"]["retirement"]),
               2
             )

      refute Retirement.valid?(Map.put(row["proof"], "backing_removed", true))
      refute Retirement.valid?(put_in(row["proof"], ~w(retirement intent source_pid), [0, 1]))
    end
  end
end
