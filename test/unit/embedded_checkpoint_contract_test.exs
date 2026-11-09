defmodule SmolBox.Embedded.CheckpointContractTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.EmbeddedReply
  alias SmolBox.{Checkpoint, Profile}
  alias SmolBox.Embedded.{Channel, CheckpointContract, Config, Launch, Request, SDKIdentity}

  test "operator approval binds capture platform, version and allocations separately from request" do
    {:ok, profile} = Profile.new("captured", cpus: 2, memory_mb: 512, storage_gb: 3)

    for {platform, architecture, host} <- [
          {:linux, "x86_64", "linux/amd64"},
          {:macos, "aarch64", "darwin/arm64"}
        ] do
      {:ok, checkpoint} =
        Checkpoint.new(
          id: "idle-v1",
          sha256: String.duplicate("a", 64),
          architecture: architecture,
          platform: platform,
          path: "/operator/idle.smolcheckpoint",
          profile: profile
        )

      assert [approval] = CheckpointContract.approvals(%{checkpoints: [checkpoint]})
      assert approval["source"] == Checkpoint.artifact(checkpoint)
      refute Map.has_key?(approval["source"], "path")
      assert approval["host_platform"] == host
      assert approval["sdk_version"] == "1.22.0"
      assert approval["max_bytes"] == 68_719_476_736

      assert approval["resources"] == %{
               "cpus" => 2,
               "memory_mib" => 512,
               "storage_gib" => 3,
               "overlay_gib" => 1
             }

      config_catalog = %{checkpoints: [checkpoint]}
      request = Map.take(approval, ["source", "resources"])
      assert CheckpointContract.approved?(config_catalog, request)

      refute CheckpointContract.approved?(
               config_catalog,
               put_in(request, ["resources", "cpus"], 1)
             )

      refute CheckpointContract.approved?(
               config_catalog,
               put_in(request, ["source", "sha256"], String.duplicate("b", 64))
             )

      config =
        struct(Config,
          id: "worker",
          artifacts: [],
          package_identity: %{"engine_version" => "0.2.0"},
          checkpoints: [checkpoint],
          sdk_identity: SDKIdentity.implemented("1.22.0", String.duplicate("a", 40))
        )

      refute Map.has_key?(Launch.helper_config(config), "approved_checkpoints")
      sdk = put_in(config.sdk_identity, ["feature_versions", "checkpoints"], 1)

      assert Launch.helper_config(%{config | sdk_identity: sdk})["approved_checkpoints"] == [
               approval
             ]
    end
  end

  test "checkpoint requests reject caller paths and dependency features and preserve observer limits" do
    create = creation()

    requests = [
      %{"operation" => "create_checkpoint", "create" => create},
      %{"operation" => "inspect_checkpoint_creation", "create" => create},
      Map.merge(Map.take(create, ["source", "resources"]), %{
        "operation" => "qualify_checkpoint_creation"
      })
    ]

    for request <- requests do
      assert Request.valid?(request, 1000, 2)
      refute Request.valid?(request, 1000, 1)
      key = if Map.has_key?(request, "create"), do: ["create", "source"], else: ["source"]

      refute Request.valid?(
               update_in(request, key, &Map.put(&1, "path", "/caller/input")),
               1000,
               2
             )

      refute Request.valid?(Map.put(request, "user", "root"), 1000, 2)
    end

    refute CheckpointContract.creation?(Map.put(create, "features", %{}))
    refute CheckpointContract.creation?(Map.put(create, "volume_mounts", []))
    assert Request.valid?(hd(requests), 86_400_000, 2)
    refute Request.valid?(Enum.at(requests, 1), 30_001, 2)
    assert Request.observation?(Enum.at(requests, 1))
    assert Request.reconciliation?(Enum.at(requests, 1))
    refute Request.reconciliation?(hd(requests))
  end

  test "checkpoint creation replies bind exact ownership and cannot mint authority for an absence request" do
    hello = fixture("hello-v2.json")["hello"]
    channel = Channel.new(hello)
    request = %{"operation" => "create_checkpoint", "create" => creation()}
    assert {:ok, 1, channel} = Channel.register(channel, request, 0, 0)
    accepted = %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
    assert {:ok, channel, {1, :accepted}} = Channel.receive_message(channel, accepted)
    reply = fixture("created-v2.json")

    assert :error =
             Channel.receive_message(
               channel,
               put_in(reply, ["outcome", "receipt", "incarnation"], String.duplicate("a", 32))
             )

    assert {:ok, _, {1, {:terminal, %{"result" => "created"}}}} =
             Channel.receive_message(channel, reply)

    request = %{request | "operation" => "inspect_checkpoint_creation"}
    assert {:ok, 1, observer} = Channel.register(Channel.new(hello), request, 0, 0)
    assert {:ok, observer, {1, :accepted}} = Channel.receive_message(observer, accepted)
    assert :error = Channel.receive_message(observer, reply)

    presence = %{
      reply
      | "outcome" => %{"result" => "creation_presence", "presence" => "unverified"}
    }

    assert {:ok, _, {1, {:terminal, %{"presence" => "unverified"}}}} =
             Channel.receive_message(observer, presence)
  end

  test "checkpoint creation inspection distinguishes absence from unverified presence" do
    context = %{identity: nil}
    request = %{"operation" => "inspect_checkpoint_creation", "create" => creation()}
    outcome = %{"result" => "creation_presence", "presence" => "absent"}
    output = %{stdout: <<>>, stderr: <<>>, file: <<>>}

    assert {:ok, :absent} =
             EmbeddedReply.decode(
               context,
               :inspect_creation,
               request,
               {:ok, outcome, output, nil}
             )

    unverified = %{outcome | "presence" => "unverified"}

    assert {:error,
            %{category: :identity_conflict, operation: :inspect, evidence: :dispatch_uncertain}} =
             EmbeddedReply.decode(context, :inspect_creation, request, {
               :ok,
               unverified,
               output,
               nil
             })
  end

  test "checkpoint source operations require v2 identity and preflight accepts only running observation" do
    hello = fixture("hello-v2.json")["hello"]
    receipt = fixture("created-v2.json")["outcome"]["receipt"]
    start = %{"operation" => "start_checkpointable", "receipt" => receipt}
    preflight = %{start | "operation" => "checkpoint_preflight"}

    for request <- [start, preflight] do
      assert Request.valid?(request, 1000, 2)
      refute Request.valid?(request, 1000, 1)

      refute Request.valid?(
               put_in(request, ["receipt"], Map.delete(receipt, "material")),
               1000,
               2
             )
    end

    assert Request.observation?(preflight)
    refute Request.observation?(start)
    refute Request.valid?(preflight, 30_001, 2)
    assert {:ok, 1, channel} = Channel.register(Channel.new(hello), preflight, 0, 0)
    accepted = %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
    assert {:ok, channel, {1, :accepted}} = Channel.receive_message(channel, accepted)

    reply = %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => %{
        "result" => "observed",
        "observation" => %{
          "state" => "stopped",
          "resources" => creation()["resources"],
          "pid_identity" => nil
        }
      }
    }

    assert :error = Channel.receive_message(channel, reply)

    running =
      reply
      |> put_in(["outcome", "observation", "state"], "running")
      |> put_in(["outcome", "observation", "pid_identity"], [123, 456])

    assert {:ok, _, {1, {:terminal, %{"result" => "observed"}}}} =
             Channel.receive_message(channel, running)
  end

  test "checkpointable marker is explicit true, v2 only and forbids competing creation topology" do
    create = Map.put(creation(), "checkpointable", true)
    assert CheckpointContract.creation?(create)
    assert Request.valid?(%{"operation" => "create_checkpoint", "create" => create}, 1000, 2)

    for value <- [false, nil, "true"],
        do: refute(CheckpointContract.creation?(%{create | "checkpointable" => value}))

    refute CheckpointContract.marker?(create, 1)

    for changed <- [
          Map.put(create, "volume_mounts", []),
          Map.put(create, "features", "invalid"),
          Map.put(create, "features", %{
            "network" => %{"enabled" => true},
            "ports" => [],
            "workload" => nil
          })
        ],
        do: refute(CheckpointContract.marker?(changed, 2))

    assert CheckpointContract.matches?(create, %{checkpointable: true}, nil)
    refute CheckpointContract.matches?(create, %{checkpointable: false}, nil)
    assert CheckpointContract.matches?(create, %{}, {"scope", "machine"})
  end

  defp creation do
    receipt = fixture("created-v2.json")["outcome"]["receipt"]

    Map.merge(Map.take(receipt, ~w(name owner_token incarnation)), %{
      "source" => %{
        "kind" => "checkpoint",
        "id" => "idle-v1",
        "sha256" => String.duplicate("a", 64),
        "architecture" => "aarch64"
      },
      "resources" => %{"cpus" => 1, "memory_mib" => 256, "storage_gib" => 1, "overlay_gib" => 1},
      "labels" => %{}
    })
  end

  defp fixture(name),
    do:
      Path.expand("../../native/smolbox-protocol/fixtures/" <> name, __DIR__)
      |> File.read!()
      |> Jason.decode!()
end
