defmodule SmolBox.EmbeddedSourceWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, CreationPayload, Protocol, Request}
  alias SmolBox.Source

  defp receipt do
    "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> hd()
    |> Map.fetch!("previous")
  end

  defp create do
    {:ok, source} =
      Source.oci(
        id: "approved-source",
        reference: "registry.example/app@sha256:" <> String.duplicate("a", 64),
        architecture: "aarch64"
      )

    receipt = receipt()

    %{
      "name" => receipt["name"],
      "owner_token" => receipt["owner_token"],
      "incarnation" => receipt["incarnation"],
      "source" => Source.artifact(source),
      "resources" => %{"cpus" => 1, "memory_mib" => 256, "storage_gib" => 1, "overlay_gib" => 1},
      "labels" => %{}
    }
  end

  defp request(operation), do: %{"operation" => operation, "create" => create()}

  defp message(channel, sequence, values),
    do: Map.merge(values, %{"epoch" => channel.epoch, "id" => 1, "sequence" => sequence})

  defp channel(request) do
    receipt = receipt()

    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("ab", 16),
        "domain" => %{
          "target_id" => receipt["target_id"],
          "generation" => receipt["domain_generation"]
        }
      })

    {:ok, 1, channel} = Channel.register(channel, request, 262_144, 64)

    {:ok, channel, _} =
      Channel.receive_message(channel, message(channel, 0, %{"type" => "accepted"}))

    channel
  end

  test "source creation/qualification/absence/start are versioned and preserve local request shapes" do
    for operation <- ~w(create_oci inspect_oci_creation) do
      assert Request.valid?(request(operation), 1000, 2)
      refute Request.valid?(request(operation), 1000, 1)
    end

    refute Request.valid?(request("create"), 1000, 2)
    assert Request.observation?(request("inspect_oci_creation"))
    refute Request.observation?(request("create_oci"))

    qualification = %{
      "operation" => "qualify_oci_creation",
      "source" => create()["source"],
      "resources" => create()["resources"],
      "user" => nil
    }

    assert Request.valid?(qualification, 30_000, 2)
    refute Request.valid?(qualification, 30_001, 2)
    start = %{"operation" => "start_oci", "source" => create()["source"], "receipt" => receipt()}
    assert Request.valid?(start, 1000, 2)
    refute Request.valid?(start, 1000, 1)
    refute Request.valid?(Map.put(start, "auth", "opaque"), 1000, 2)
  end

  test "source wire rejects mixed pack authority, tags, changed digests and credential fields" do
    for changed <- [
          Map.put(create(), "artifact", %{}),
          put_in(create()["source"]["sha256"], String.duplicate("b", 64)),
          put_in(create()["source"]["reference"], "registry.example/app:tag"),
          put_in(create()["source"]["credential_ref"], "invented"),
          put_in(create()["source"]["architecture"], "invalid"),
          Map.put(create(), "features", nil)
        ] do
      refute Request.valid?(%{"operation" => "create_oci", "create" => changed}, 1000, 2)
    end
  end

  test "created source completion binds exact intent and cannot carry crossed stream or presence evidence" do
    channel = channel(request("create_oci"))

    assert :error =
             Channel.receive_message(
               channel,
               message(channel, 1, %{
                 "type" => "event",
                 "event" => %{"stream" => "file", "data_base64" => Base.encode64("x")}
               })
             )

    for outcome <- [
          %{"result" => "created", "receipt" => Map.put(receipt(), "name", "foreign")},
          %{"result" => "creation_presence", "presence" => "absent"}
        ] do
      assert :error =
               Channel.receive_message(
                 channel,
                 message(channel, 1, %{"type" => "terminal", "outcome" => outcome})
               )
    end

    outcome = %{"result" => "created", "receipt" => receipt()}
    assert Protocol.valid_outcome?(outcome, 2)

    assert {:ok, retired, _} =
             Channel.receive_message(
               channel,
               message(channel, 1, %{"type" => "terminal", "outcome" => outcome})
             )

    assert :error =
             Channel.receive_message(
               retired,
               message(retired, 1, %{"type" => "terminal", "outcome" => outcome})
             )
  end

  test "compact source workloads use existing bounded codec without altering source authority" do
    features = %{
      "network" => %{"enabled" => false, "hosts" => [], "cidrs" => []},
      "ports" => [],
      "workload" => %{
        "entrypoint" => ["/app"],
        "cmd" => [],
        "env" => %{"A" => String.duplicate("\x01", 8192)},
        "workdir" => "/"
      }
    }

    assert {:ok, payload} = CreationPayload.encode(features)
    assert payload["schema"] == 1

    assert Request.valid?(
             put_in(request("create_oci"), ["create", "features"], features),
             1000,
             2
           )

    assert create()["source"]["sha256"] == String.duplicate("a", 64)
  end
end
