defmodule SmolBox.Embedded.BranchPreflightTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Assignment, Binding, Budget, EmbeddedContext, EmbeddedReply}
  alias SmolBox.Embedded.{Call, Channel, Config, Identity, Limits, Request}
  alias SmolBox.{ManagedMachineSpec, Profile}

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  @fixture Path.join(@fixtures, "branch-preflight-v1.json")
  @external_resource @fixture
  @source Jason.decode!(File.read!(@fixture))
  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  # Bridge-contract peer only: no native helper, SDK or VM. The real Call/Port
  # submission path must still admit the bounded request in the intended state.
  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:health, _, state), do: {:reply, {:ok, state.health}, state}

    def handle_call({:submit, request, _, observer, _, epoch}, _, state) do
      true = epoch == state.health.epoch
      handle = make_ref()
      send(state.observer, {:source_probe_admitted, request})
      send(observer, {:smolbox_embedded, handle, :accepted})
      send(observer, {:smolbox_embedded, handle, {:terminal, state.outcome, nil}})
      {:reply, {:ok, handle}, state}
    end
  end

  defp context(status) do
    receipt = @source["operation"]["receipt"]

    native =
      struct(Config,
        id: receipt["target_id"],
        domain_generation: receipt["domain_generation"],
        package_identity: %{"engine_version" => "0.2.0"},
        package_manifest_sha256: String.duplicate("1", 64),
        limits: %Limits{}
      )

    health = %{
      status: status,
      epoch: String.duplicate("a", 32),
      target_id: native.id,
      generation: native.domain_generation,
      package_identity: native.package_identity,
      package_manifest_sha256: native.package_manifest_sha256,
      protocol_major: 2
    }

    peer =
      start_supervised!({Peer, %{observer: self(), health: health, outcome: @source["outcome"]}})

    %EmbeddedContext{config: native, server: peer, pinned: true, epoch: health.epoch}
  end

  test "shared source preflight requires exact bounded major-two material authority" do
    request = @source["operation"]
    assert Request.valid?(request, 30_000, 2)
    refute Request.valid?(request, 30_001, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.observation?(request)
    refute Request.control?(request)
    assert Request.reconciliation?(request)
    refute Request.valid?(put_in(request, ["receipt", "material"], nil), 1000, 2)

    for field <- ~w(path pid idle policy create quiesced),
        do: refute(Request.valid?(Map.put(request, field, true), 1000, 2))
  end

  test "quiesced original-result recovery can obtain fresh source evidence through the real call gate" do
    context = context(:reconciling)
    request = @source["operation"]

    assert {:ok, outcome, output, nil} =
             Call.run(context, request, %Budget{
               timeout_ms: 1000,
               max_request_bytes: 16_384,
               max_response_bytes: 16_384
             })

    assert outcome == @source["outcome"] and output == empty()
    assert_received {:source_probe_admitted, ^request}
  end

  test "source preflight does not gain quarantined control admission" do
    assert {:error, _} =
             Call.run(context(:quarantined), @source["operation"], %Budget{
               timeout_ms: 1000,
               max_request_bytes: 16_384,
               max_response_bytes: 16_384
             })

    refute_received {:source_probe_admitted, _}
  end

  test "malformed source authority cannot use reconciliation admission" do
    request = Map.put(@source["operation"], "receipt", nil)
    refute Request.reconciliation?(request)

    assert {:error, _} =
             Call.run(context(:reconciling), request, %Budget{
               timeout_ms: 1000,
               max_request_bytes: 16_384,
               max_response_bytes: 16_384
             })

    refute_received {:source_probe_admitted, _}
  end

  test "channel requires running offline unmounted evidence and rejects all streams" do
    hello =
      @fixtures
      |> Path.join("hello-v2.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("hello")

    assert {:ok, 1, channel} = Channel.register(Channel.new(hello), @source["operation"], 1024, 1)
    accepted = %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
    assert {:ok, channel, {1, :accepted}} = Channel.receive_message(channel, accepted)

    reply = %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => @source["outcome"]
    }

    observed = @source["outcome"]["observation"]

    for invalid <- invalid_observations(observed) do
      refute match?(
               {:ok, _, _},
               Channel.receive_message(
                 channel,
                 put_in(reply, ["outcome", "observation"], invalid)
               )
             )
    end

    for stream <- ~w(stdout stderr file checkpoint) do
      event = %{
        "type" => "event",
        "epoch" => channel.epoch,
        "id" => 1,
        "sequence" => 1,
        "event" => %{"stream" => stream, "data_base64" => Base.encode64("unexpected")}
      }

      assert :error = Channel.receive_message(channel, event)
    end

    assert {:ok, _, {1, {:terminal, %{"result" => "observed"}}}} =
             Channel.receive_message(channel, reply)

    assert :error =
             Channel.receive_message(channel, %{reply | "outcome" => %{"result" => "qualified"}})
  end

  test "scoped reply keeps source receipt and rejects changed authority resources or output" do
    request = @source["operation"]
    receipt = request["receipt"]
    resources = @source["outcome"]["observation"]["resources"]
    {:ok, profile} = Profile.new("source")

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "branch",
        id: "source",
        profile: profile,
        artifact: %{
          "id" => "bare",
          "sha256" => String.duplicate("d", 64),
          "architecture" => "aarch64"
        }
      )

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: receipt["target_id"],
        generation: receipt["domain_generation"]
      },
      creation: %{"resources" => resources}
    }

    context = %EmbeddedContext{
      config: struct(Config),
      server: self(),
      assignment: assignment,
      name: receipt["name"],
      identity: %Identity{receipt: receipt},
      spec: spec
    }

    result = {:ok, @source["outcome"], empty(), nil}
    assert {:ok, observed} = EmbeddedReply.decode(context, :branch_source, request, result)
    assert observed.state == :running and observed.network == :offline and observed.ports == []
    assert observed.backend_identity.receipt == receipt
    assert observed.backend_identity.pid_identity == [123, 456]

    for observation <-
          invalid_observations(@source["outcome"]["observation"]) ++
            [put_in(@source["outcome"]["observation"], ["resources", "cpus"], 2)] do
      invalid = {:ok, %{"result" => "observed", "observation" => observation}, empty(), nil}
      assert {:error, _} = EmbeddedReply.decode(context, :branch_source, request, invalid)
    end

    for invalid <- [
          {:ok, @source["outcome"], %{empty() | stdout: "extra"}, nil},
          {:ok, @source["outcome"], %{empty() | file: "extra"}, nil},
          {:ok, Map.put(@source["outcome"], "extra", true), empty(), nil},
          {:ok, @source["outcome"], empty(),
           %SmolBox.Error{category: :unknown, operation: :branch}}
        ],
        do: assert({:error, _} = EmbeddedReply.decode(context, :branch_source, request, invalid))

    crossed = put_in(request, ["receipt", "incarnation"], String.duplicate("e", 32))
    assert {:error, _} = EmbeddedReply.decode(context, :branch_source, crossed, result)
  end

  defp invalid_observations(observed) do
    config = observed["configuration"]

    [
      %{observed | "state" => "stopped", "pid_identity" => nil},
      %{observed | "resources" => nil},
      %{observed | "pid_identity" => nil},
      Map.delete(observed, "configuration"),
      %{
        observed
        | "configuration" => %{
            config
            | "ports" => [%{"host" => 43_000, "guest" => 8080}],
              "backend" => "virtio-net"
          }
      },
      %{
        observed
        | "configuration" => %{
            config
            | "network" => %{"enabled" => true, "hosts" => ["example.invalid"], "cidrs" => []},
              "backend" => "virtio-net"
          }
      },
      put_in(observed, ["configuration", "mounts"], [
        %{
          "source" => "/private/volume",
          "target" => "/mnt/volumes/owned",
          "readonly" => false,
          "staged" => false
        }
      ])
    ]
  end
end
