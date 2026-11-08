defmodule SmolBox.EmbeddedVolumeWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, JSON, Protocol, Request, VolumeContract}

  defp fixture do
    {:ok, fixture} =
      File.read!("native/smolbox-protocol/fixtures/volume-authority.json") |> JSON.decode()

    fixture
  end

  defp operation(action) do
    request = put_in(fixture()["request"]["action"], action)["request"]
    %{"operation" => "volume", "request" => request}
  end

  defp outcome(status) do
    original = fixture()["outcome"]["volume"]["proof"]

    proof =
      case status do
        "deleted" ->
          %{"schema" => 1, "operation_id" => String.duplicate("d", 32), "provision" => original}

        "aborted" ->
          Map.put(original, "operation_id", String.duplicate("d", 32))

        _ ->
          original
      end

    volume =
      if status in ~w(absent unverified),
        do: %{"status" => status},
        else: %{"status" => status, "proof" => proof}

    %{"result" => "volume", "volume" => volume}
  end

  test "all actions have exact shape, deadline, generated identity and positive fencing" do
    for action <-
          ~w(provision delete qualify_deletion inspect_provision inspect_deletion inspect_abort) do
      request = operation(%{"action" => action})
      assert Request.valid?(request, 1000, 2)
      refute Request.valid?(request, 1000, 1)
      refute Request.valid?(put_in(request["request"]["root"], "/caller"), 1000, 2)
      refute Request.valid?(put_in(request["request"]["action"]["quiesced"], true), 1000, 2)
      observation = String.starts_with?(action, "inspect_")
      assert Request.observation?(request) == observation
      assert Request.reconciliation?(request) == observation
      assert Request.valid?(request, 86_400_000, 2) == not observation
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 86_400_001, 2)
    end

    for action <- ~w(resolve_deletion abort_staging) do
      request = operation(%{"action" => action, "quiesced" => true})
      assert Request.valid?(request, 86_400_000, 2)
      refute Request.observation?(request)
      assert Request.reconciliation?(request)
      refute Request.valid?(put_in(request["request"]["action"]["quiesced"], false), 1000, 2)

      refute Request.valid?(
               update_in(request["request"]["action"], &Map.delete(&1, "quiesced")),
               1000,
               2
             )
    end

    request = operation(%{"action" => "provision"})

    for id <- ["foreign", "sbv-ABC", "../volume", "sbv-" <> String.duplicate("A", 32)],
        do:
          refute(
            Request.valid?(put_in(request["request"]["intent"]["worker_volume_id"], id), 1, 2)
          )

    for size <- [0, 1025, 1.0, nil],
        do: refute(Request.valid?(put_in(request["request"]["intent"]["size_gb"], size), 1, 2))
  end

  test "shared Rust proof preserves full u64 values and strict nested authority" do
    proof = fixture()["outcome"]
    assert Protocol.valid_outcome?(proof, 2)
    refute Protocol.valid_outcome?(proof, 1)
    assert VolumeContract.backing(proof)["root_inode"] == 18_446_744_073_709_551_615
    {:ok, <<_length::32, body::binary>>} = JSON.encode(proof)
    assert {:ok, ^proof} = JSON.decode(body)

    for {path, value} <- [
          {~w(volume proof schema), 2},
          {~w(volume proof schema), 1.0},
          {~w(volume proof backing schema), 1.0},
          {~w(volume proof backing device), 1.0},
          {~w(volume proof backing mode), 448.0},
          {~w(volume proof account uid), 0},
          {~w(volume proof account gid), 4_294_967_296},
          {~w(volume proof backing mode), 511},
          {~w(volume proof backing inode), 0},
          {~w(volume proof backing root_inode), 18_446_744_073_709_551_616},
          {~w(volume proof backing device), 2},
          {~w(volume proof backing owner_token), "bad"},
          {~w(volume proof backing policy root), "/srv/../volumes"},
          {~w(volume proof backing unexpected), true},
          {~w(volume proof account unexpected), true}
        ] do
      refute Protocol.valid_outcome?(put_in(proof, path, value), 2)
    end
  end

  test "every status correlates only with its permitted action" do
    allowed = %{
      "provision" => ~w(provisioned),
      "delete" => ~w(deleted),
      "resolve_deletion" => ~w(deleted),
      "abort_staging" => ~w(aborted),
      "inspect_provision" => ~w(provisioned absent unverified),
      "inspect_deletion" => ~w(deleted unverified),
      "inspect_abort" => ~w(aborted unverified),
      "qualify_deletion" => ~w(qualified)
    }

    for {action, statuses} <- allowed do
      value = %{"action" => action}

      value =
        if action in ~w(resolve_deletion abort_staging),
          do: Map.put(value, "quiesced", true),
          else: value

      request = operation(value)["request"]

      for status <- ~w(provisioned deleted aborted qualified absent unverified) do
        assert Protocol.valid_outcome?(outcome(status), 2)

        assert VolumeContract.matches?(outcome(status), request, fixture()["domain"]) ==
                 status in statuses
      end
    end
  end

  test "channel rejects crossed proofs and valid output events before accepting exact completion" do
    request = operation(%{"action" => "provision"})

    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("e", 32),
        "domain" => fixture()["domain"]
      })

    {:ok, 1, channel} = Channel.register(channel, request, 262_144, 64)
    base = %{"epoch" => channel.epoch, "id" => 1}

    {:ok, channel, _} =
      Channel.receive_message(channel, Map.merge(base, %{"type" => "accepted", "sequence" => 0}))

    proof = outcome("provisioned")

    for {path, value} <- [
          {~w(volume proof backing target_id), "other"},
          {~w(volume proof backing domain_generation), String.duplicate("f", 32)},
          {~w(volume proof backing policy id), "other"},
          {~w(volume proof backing intent size_gb), 5},
          {~w(volume proof backing intent worker_volume_id), "sbv-" <> String.duplicate("f", 32)}
        ] do
      changed = put_in(proof, path, value)
      assert Protocol.valid_outcome?(changed, 2)

      assert :error ==
               Channel.receive_message(
                 channel,
                 Map.merge(base, %{"type" => "terminal", "sequence" => 1, "outcome" => changed})
               )
    end

    event =
      Map.merge(base, %{
        "type" => "event",
        "sequence" => 1,
        "event" => %{"stream" => "stdout", "data_base64" => Base.encode64("bad")}
      })

    assert {:ok, ^event} = Protocol.decode(Jason.encode!(event), 2)
    assert :error == Channel.receive_message(channel, event)

    assert {:ok, _, _} =
             Channel.receive_message(
               channel,
               Map.merge(base, %{"type" => "terminal", "sequence" => 1, "outcome" => proof})
             )
  end

  test "operator catalog binds the result root in addition to request policy ID" do
    request = operation(%{"action" => "provision"})["request"]
    policy = %{id: "local", root: "/srv/smolvm/volumes"}
    assert VolumeContract.approved?(request, policy)
    refute VolumeContract.approved?(request, %{policy | id: "other"})
    refute VolumeContract.approved?(request, nil)
    assert VolumeContract.approved_result?(outcome("provisioned"), policy)

    changed =
      put_in(outcome("provisioned"), ~w(volume proof backing policy root), "/other/volumes")

    assert Protocol.valid_outcome?(changed, 2)
    refute VolumeContract.approved_result?(changed, policy)
    refute VolumeContract.approved_result?(outcome("unverified"), nil)
  end

  test "quarantine admits only nonmutating volume inspections and no legacy volume requests" do
    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("e", 32),
        "domain" => fixture()["domain"]
      })

    {:ok, channel, :unavailable} =
      Channel.receive_message(channel, %{"type" => "unavailable", "epoch" => channel.epoch})

    for action <- ~w(inspect_provision inspect_deletion inspect_abort) do
      assert {:ok, _, _} = Channel.register(channel, operation(%{"action" => action}), 0, 0)
    end

    for action <- ~w(provision delete qualify_deletion) do
      assert :error == Channel.register(channel, operation(%{"action" => action}), 0, 0)
    end

    assert :error ==
             Channel.register(
               %{channel | major: 1},
               operation(%{"action" => "inspect_provision"}),
               0,
               0
             )
  end
end
