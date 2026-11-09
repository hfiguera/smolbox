defmodule SmolBox.Embedded.UnbootedBranchDisposalCandidateTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Protocol, Request}
  alias SmolBox.Embedded.UnbootedBranchDisposalCandidate, as: Candidate
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "unbooted-branch-disposal-candidate-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")

  defp operation(row),
    do: %{
      "operation" => "inspect_unbooted_branch_disposal",
      "request" => row["creation"],
      "quiesced" => true
    }

  defp outcome(row),
    do: %{"result" => "unbooted_branch_disposal_candidate", "candidate" => row["candidate"]}

  defp hello(row) do
    @hello
    |> Map.put("epoch", get_in(row, ~w(candidate publication change child_origin intent epoch)))
    |> put_in(~w(package platform), get_in(row, ~w(candidate publication change platform)))
    |> put_in(~w(domain target_id), get_in(row, ~w(creation source target_id)))
    |> put_in(~w(domain generation), get_in(row, ~w(creation source domain_generation)))
  end

  defp accepted(row) do
    channel = %{Channel.new(hello(row)) | unavailable: true}
    assert {:ok, 1, channel} = Channel.register(channel, operation(row), 1024, 1)

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

  test "shared synthetic readers retain full correlation and redact original context" do
    for row <- @rows do
      assert {:ok, proof} = Candidate.from_wire(row["candidate"])
      assert Candidate.valid?(proof)
      assert Candidate.to_wire(proof) == row["candidate"]
      assert Candidate.matches?(proof, row["creation"])
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ row["creation"]["child"]["owner_token"]

      refute inspect(proof) =~
               get_in(row, ~w(candidate publication change child_origin intent epoch))

      assert :error = Candidate.from_wire(proof)
      refute Candidate.valid?(Map.put(proof, :extra, true))
    end
  end

  test "source scoped control requests require quiescence exact keys material and finite budget" do
    for row <- @rows do
      operation = operation(row)
      assert Request.valid?(operation, 30_000, 2)
      refute Request.valid?(operation, 30_001, 2)
      refute Request.valid?(operation, 1000, 1)
      assert Request.receipt(operation) == row["creation"]["source"]
      assert Request.control?(operation) and Request.reconciliation?(operation)
      refute Request.valid?(Map.put(operation, "quiesced", false), 1000, 2)
      refute Request.valid?(put_in(operation, ~w(request source material), nil), 1000, 2)

      for key <- ~w(path pid child_absent dispatched) do
        refute Request.valid?(Map.put(operation, key, true), 1000, 2)
        assert :error = Candidate.from_wire(Map.put(row["candidate"], key, true))
      end
    end
  end

  test "candidate cannot be child disposal absence readiness or a nullable answer" do
    for row <- @rows do
      for value <- [
            nil,
            row["creation"],
            Map.delete(row["candidate"], "publication"),
            Map.put(row["candidate"], "schema", 2),
            Map.put(row["candidate"], "preparation_sha256", "invalid")
          ] do
        assert :error = Candidate.from_wire(value)
      end

      refute Protocol.valid_outcome?(%{"result" => "unbooted_branch_disposal_candidate"}, 2)

      refute Protocol.valid_outcome?(
               %{"result" => "unbooted_branch_disposal_candidate", "candidate" => nil},
               2
             )
    end
  end

  test "channel accepts only exact full creation original epoch platform and zero streams" do
    for row <- @rows do
      channel = accepted(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

      for {field, value} <- [{:epoch, String.duplicate("0", 32)}, {:platform, "foreign"}] do
        changed = Map.put(channel, field, value)
        assert :error = Channel.receive_message(changed, terminal(changed, outcome(row)))
      end

      assert :error =
               Channel.receive_message(channel, terminal(channel, %{"result" => "qualified"}))

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

      changed = put_in(row, ~w(creation child name), "other-child")
      changed_channel = accepted(changed)

      assert :error =
               Channel.receive_message(changed_channel, terminal(changed_channel, outcome(row)))
    end
  end

  test "a valid new hash cannot rebind an unused initial release to the original request" do
    for row <- @rows, row["creation"]["initial_release"] != nil do
      changed =
        put_in(row["candidate"], ~w(creation initial_release operation_id), "different-release")

      changed = Map.put(changed, "proof_sha256", Candidate.proof_digest(changed))
      assert Candidate.valid?(changed)
      refute Candidate.matches?(changed, row["creation"])
      channel = accepted(row)

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, %{
                   "result" => "unbooted_branch_disposal_candidate",
                   "candidate" => changed
                 })
               )
    end
  end
end
