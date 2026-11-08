defmodule SmolBox.Embedded.UnbootedBranchChildAbsenceTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    Channel,
    Protocol,
    Request,
    UnbootedBranchDisposal
  }

  alias SmolBox.Embedded.UnbootedBranchChildAbsence, as: Absence
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "unbooted-branch-child-absence-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  defp request(row), do: row["proof"]["request"]

  defp operation(row),
    do: %{"operation" => "qualify_unbooted_branch_child_absence", "request" => request(row)}

  defp outcome(row), do: %{"result" => "unbooted_branch_child_absent", "proof" => row["proof"]}

  defp hello(row) do
    @hello
    |> Map.put("epoch", Absence.epoch(request(row)))
    |> put_in(~w(package platform), Absence.platform(request(row)))
    |> put_in(~w(domain target_id), get_in(request(row), ~w(disposal creation source target_id)))
    |> put_in(
      ~w(domain generation),
      get_in(request(row), ~w(disposal creation source domain_generation))
    )
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

  test "shared fixture readers preserve exact original disposal provenance and redact all authority" do
    for row <- @rows do
      assert Absence.request?(request(row))
      assert {:ok, proof} = Absence.from_wire(row["proof"])
      assert Absence.valid?(proof) and Absence.matches?(proof, request(row))
      assert Absence.to_wire(proof) == row["proof"]
      assert Protocol.valid_outcome?(outcome(row), 2)
      refute Protocol.valid_outcome?(outcome(row), 1)
      refute inspect(proof) =~ get_in(request(row), ~w(disposal creation child owner_token))
      refute inspect(proof) =~ Absence.epoch(request(row))
      assert :error = Absence.from_wire(proof)
      refute Absence.valid?(Map.put(proof, :extra, true))
    end
  end

  test "only fenced protocol-two requests with a distinct canonical intent and finite budget can be control observations" do
    for row <- @rows do
      operation = operation(row)
      assert Request.valid?(operation, 30_000, 2)
      refute Request.valid?(operation, 30_001, 2)
      refute Request.valid?(operation, 1000, 1)

      assert Request.control?(operation) and Request.observation?(operation) and
               Request.reconciliation?(operation)

      assert Request.receipt(operation) == get_in(request(row), ~w(disposal creation source))
      wrong = Map.put(request(row), "quiesced", false)
      wrong = Map.put(wrong, "request_sha256", Absence.request_digest(wrong))
      refute Absence.request?(wrong)
      refute Request.control?(%{operation | "request" => wrong})

      for id <- [
            get_in(request(row), ~w(disposal creation child operation_id)),
            get_in(request(row), ~w(disposal request operation_id)),
            get_in(request(row), ~w(disposal creation initial_release operation_id))
          ],
          id != nil do
        wrong = Map.put(request(row), "operation_id", id)
        refute Absence.request?(Map.put(wrong, "request_sha256", Absence.request_digest(wrong)))
      end
    end
  end

  test "exact keys typed results and original disposal cannot become nullable absence or backing authority" do
    for row <- @rows do
      for key <- ~w(path pid completion backing_removed) do
        refute Absence.request?(Map.put(request(row), key, true))
        assert :error = Absence.from_wire(Map.put(row["proof"], key, true))
        refute Request.valid?(Map.put(operation(row), key, true), 1000, 2)
      end

      refute Protocol.valid_outcome?(%{"result" => "unbooted_branch_child_absent"}, 2)

      refute Protocol.valid_outcome?(
               %{"result" => "unbooted_branch_child_absent", "proof" => nil},
               2
             )

      refute Absence.valid?(request(row)["disposal"])
      refute BranchBackingRelease.request?(request(row))
      refute UnbootedBranchDisposal.request?(request(row))
      {:ok, typed} = UnbootedBranchDisposal.from_wire(request(row)["disposal"])
      refute Absence.request?(%{request(row) | "disposal" => typed})
    end
  end

  test "original epoch platform and domain must match before subscription admission" do
    for row <- @rows do
      channel = Channel.new(hello(row))

      for wrong <- [
            %{channel | epoch: String.duplicate("0", 32)},
            %{channel | platform: "foreign"},
            put_in(channel.domain["generation"], String.duplicate("0", 32))
          ] do
        assert :error = Channel.register(wrong, operation(row), 1024, 1)
      end
    end
  end

  test "channel allows only the exact zero-stream proof even after ordinary work becomes unavailable" do
    for row <- @rows do
      channel = accepted(row)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row)))

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

      for outcome <- [
            %{"result" => "qualified"},
            %{"result" => "unbooted_branch_disposed", "proof" => request(row)["disposal"]}
          ] do
        assert :error = Channel.receive_message(channel, terminal(channel, outcome))
      end
    end
  end

  test "valid new request and proof hashes cannot satisfy an older original intent" do
    for row <- @rows do
      wrong = Map.put(request(row), "operation_id", "different-retirement")
      wrong = Map.put(wrong, "request_sha256", Absence.request_digest(wrong))
      assert Absence.request?(wrong)
      proof = %{row["proof"] | "request" => wrong}
      proof = Map.put(proof, "proof_sha256", Absence.proof_digest(proof))
      assert Absence.valid?(proof)
      refute Absence.matches?(proof, request(row))
      channel = accepted(row)

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, %{"result" => "unbooted_branch_child_absent", "proof" => proof})
               )
    end
  end
end
