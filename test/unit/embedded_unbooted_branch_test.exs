defmodule SmolBox.Embedded.UnbootedBranchTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{BranchBackingRelease, Channel, Protocol, Request}
  alias SmolBox.Embedded.UnbootedBranchBackingRelease, as: Backing
  alias SmolBox.Embedded.UnbootedBranchDisposal, as: Disposal
  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "unbooted-branch-disposal-v1.json")
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @hello @fixtures
         |> Path.join("hello-v2.json")
         |> File.read!()
         |> Jason.decode!()
         |> Map.fetch!("hello")
  defp operation(row, name),
    do: %{
      "operation" => name,
      "request" =>
        row[if(name == "release_unbooted_branch_backing", do: "backing_request", else: "request")]
    }

  defp outcome(row, name),
    do: %{
      "result" =>
        if(name == "release_unbooted_branch_backing",
          do: "branch_backing_released",
          else: "unbooted_branch_disposed"
        ),
      "proof" =>
        row[if(name == "release_unbooted_branch_backing", do: "backing_proof", else: "proof")]
    }

  defp hello(row) do
    @hello
    |> put_in(~w(domain target_id), row["request"]["creation"]["source"]["target_id"])
    |> put_in(~w(domain generation), row["request"]["creation"]["source"]["domain_generation"])
    |> put_in(~w(package platform), row["proof"]["publication"]["change"]["platform"])
  end

  defp channel(row, name) do
    channel = Channel.new(hello(row))
    {:ok, 1, channel} = Channel.register(channel, operation(row, name), 1024, 1)

    {:ok, channel, {1, :accepted}} =
      Channel.receive_message(channel, %{
        "type" => "accepted",
        "epoch" => channel.epoch,
        "id" => 1,
        "sequence" => 0
      })

    channel
  end

  defp terminal(channel, result),
    do: %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => result
    }

  defp request_digest(request),
    do:
      put_in(
        request,
        ~w(request request_sha256),
        Disposal.request_digest(request["request"], request["creation"])
      )

  test "shared native fixtures preserve full creation and distinct completion provenance" do
    for row <- @rows do
      assert Disposal.request?(row["request"])
      assert {:ok, proof} = Disposal.from_wire(row["proof"])
      assert Disposal.valid?(proof) and Disposal.matches?(proof, row["request"])
      assert Disposal.to_wire(proof) == row["proof"]
      refute inspect(proof) =~ row["proof"]["creation"]["child"]["owner_token"]
      assert :error = Disposal.from_wire(proof)
      assert Backing.request?(row["backing_request"])
      assert {:ok, release} = BranchBackingRelease.from_wire(row["backing_proof"])
      assert Backing.matches?(release, row["backing_request"])
      refute Backing.request?(put_in(row["backing_request"], ["disposal"], proof))
    end
  end

  test "requests use protocol two bounded controls and exact source or child scope" do
    for row <- @rows,
        name <-
          ~w(dispose_unbooted_branch resolve_unbooted_branch_disposal release_unbooted_branch_backing) do
      op = operation(row, name)
      assert Request.valid?(op, 30_000, 2)
      refute Request.valid?(op, 30_001, 2)
      refute Request.valid?(op, 1000, 1)
      assert Request.control?(op) and Request.reconciliation?(op)
      refute Request.observation?(op)

      assert Request.receipt(op) ==
               if(name == "release_unbooted_branch_backing",
                 do: row["backing_request"]["child"],
                 else: row["request"]["creation"]["source"]
               )

      assert Protocol.valid_outcome?(outcome(row, name), 2)
      refute Protocol.valid_outcome?(outcome(row, name), 1)
      refute Request.valid?(Map.put(op, "path", "/foreign"), 1000, 2)
    end
  end

  test "zero output correlated terminal results cannot become bare absence or generic success" do
    for row <- @rows,
        name <-
          ~w(dispose_unbooted_branch resolve_unbooted_branch_disposal release_unbooted_branch_backing) do
      channel = channel(row, name)

      assert {:ok, _, {1, {:terminal, _}}} =
               Channel.receive_message(channel, terminal(channel, outcome(row, name)))

      assert :error =
               Channel.receive_message(channel, terminal(channel, %{"result" => "qualified"}))

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, Map.put(outcome(row, name), "proof", nil))
               )

      pending = put_in(channel.pending[1].output_bytes, 1)
      assert :error = Channel.receive_message(pending, terminal(pending, outcome(row, name)))

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
    end
  end

  test "changed authority and initial activation choice cannot replace the original request" do
    for row <- @rows do
      for {path, value} <- [
            {~w(creation approval id), "different-policy"},
            {~w(creation child name), "different-child"},
            {~w(creation source domain_generation), String.duplicate("0", 32)}
          ] do
        changed = row["request"] |> put_in(path, value) |> request_digest()
        assert Disposal.request?(changed)
        refute Disposal.matches?(row["proof"], changed)
      end

      if row["request"]["creation"]["initial_release"] do
        changed =
          row["request"]
          |> put_in(~w(creation initial_release operation_id), "different-activation")
          |> request_digest()

        assert Disposal.request?(changed)
        refute Disposal.matches?(row["proof"], changed)
      end
    end
  end

  test "fencing distinct IDs required fields and provenance are strict" do
    for row <- @rows do
      refute Disposal.request?(
               request_digest(put_in(row["request"], ~w(request quiesced), false))
             )

      refute Disposal.request?(
               request_digest(
                 put_in(
                   row["request"],
                   ~w(request operation_id),
                   row["request"]["creation"]["child"]["operation_id"]
                 )
               )
             )

      refute Disposal.valid?(Map.delete(row["proof"], "completion"))
      refute Disposal.valid?(Map.put(row["proof"], "completion", "booted"))
      flipped = if row["proof"]["completion"] == "deleted", do: "resolved_absent", else: "deleted"
      refute Disposal.valid?(Map.put(row["proof"], "completion", flipped))

      for key <- ~w(pid path native_bytes completion) do
        refute Disposal.request?(Map.put(row["request"], key, 1))
      end
    end
  end

  test "backing request preserves the exact unbooted root and explicit host confirmations" do
    for row <- @rows do
      request = row["backing_request"]

      for {path, value} <- [
            {["quiesced"], false},
            {["backing_removed"], false},
            {~w(child owner_token), String.duplicate("f", 64)},
            {~w(source owner_token), String.duplicate("f", 64)},
            {["operation_id"], request["disposal"]["request"]["operation_id"]}
          ] do
        changed = put_in(request, path, value)
        changed = Map.put(changed, "request_sha256", Backing.request_digest(changed))
        refute Backing.request?(changed)
      end

      refute Backing.matches?(Map.put(row["backing_proof"], "native_bytes", 1), request)
      refute Backing.request?(Map.put(request, "completion", %{}))
    end
  end

  test "helper platform and domain are bound independently of valid proof hashes" do
    for row <- @rows do
      h = hello(row)
      wrong = Channel.new(put_in(h, ~w(domain generation), String.duplicate("0", 32)))
      assert :error = Channel.register(wrong, operation(row, "dispose_unbooted_branch"), 0, 0)
      platform = if h["package"]["platform"] == "macos", do: "linux", else: "macos"
      channel = %{channel(row, "dispose_unbooted_branch") | platform: platform}

      assert :error =
               Channel.receive_message(
                 channel,
                 terminal(channel, outcome(row, "dispose_unbooted_branch"))
               )

      assert :error =
               Channel.register(
                 Channel.new(put_in(h, ~w(package platform), platform)),
                 operation(row, "release_unbooted_branch_backing"),
                 0,
                 0
               )
    end
  end
end
