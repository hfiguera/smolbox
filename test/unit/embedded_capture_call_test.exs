defmodule SmolBox.Embedded.CaptureCallTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedContext}
  alias SmolBox.Embedded.{Call, Config}

  defmodule Peer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    def init(state),
      do: {:ok, Map.merge(state, %{credits: [], submits: 0, observer: nil, handle: nil})}

    def handle_call(:health, _from, state), do: {:reply, {:ok, state.health}, state}
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call({:submit, _request, _budget, observer, _deadline, _epoch}, _from, state) do
      handle = make_ref()
      send(observer, {:smolbox_embedded, handle, :accepted})

      send(
        observer,
        {:smolbox_embedded, handle, {:output, :checkpoint, String.duplicate("c", 256)}}
      )

      {:reply, {:ok, handle},
       %{state | submits: state.submits + 1, observer: observer, handle: handle}}
    end

    def handle_call({:acknowledge, handle, bytes}, _from, %{handle: handle} = state) do
      state = %{state | credits: state.credits ++ [bytes]}

      if match?([_], state.credits),
        do:
          send(
            state.observer,
            {:smolbox_embedded, handle, {:output, :checkpoint, String.duplicate("c", 256)}}
          ),
        else: send(state.observer, {:smolbox_embedded, handle, {:terminal, state.outcome, nil}})

      {:reply, :ok, state}
    end

    def handle_call({:cancel, handle}, _from, state) do
      send(
        state.observer,
        {:smolbox_embedded, handle,
         {:terminal,
          %{"result" => "error", "code" => "cancelled", "dispatch" => "may_have_dispatched"}, nil}}
      )

      {:reply, :ok, state}
    end
  end

  defmodule ControlPeer do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, Map.put(state, :submits, [])}
    def handle_call(:health, _, state), do: {:reply, {:ok, state.health}, state}
    def handle_call(:state, _, state), do: {:reply, state, state}

    def handle_call({:submit, request, _budget, observer, _deadline, epoch}, _, state) do
      handle = make_ref()
      send(observer, {:smolbox_embedded, handle, :accepted})
      send(observer, {:smolbox_embedded, handle, {:terminal, state.outcome, nil}})
      {:reply, {:ok, handle}, %{state | submits: [{request, epoch} | state.submits]}}
    end
  end

  defp context do
    fixture =
      Path.expand("../../native/smolbox-protocol/fixtures/capture-transitions-v1.json", __DIR__)

    [first, _] = fixture |> File.read!() |> Jason.decode!()
    receipt = first["previous"]
    package = %{"engine_version" => "0.2.0"}

    config =
      struct(Config,
        id: receipt["target_id"],
        domain_generation: receipt["domain_generation"],
        package_identity: package,
        package_manifest_sha256: "fixture"
      )

    health = %{
      status: :ready,
      epoch: String.duplicate("a", 32),
      target_id: config.id,
      generation: config.domain_generation,
      package_identity: package,
      package_manifest_sha256: "fixture"
    }

    owner =
      start_supervised!(
        {Peer, %{health: health, outcome: %{"result" => "captured", "transition" => first}}}
      )

    context = %EmbeddedContext{config: config, server: owner}

    request = %{
      "operation" => "capture_checkpoint",
      "receipt" => receipt,
      "operation_id" => "capture-1",
      "request" => first["change"]["intent"]["request"]
    }

    budget = %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 256}
    {context, request, budget, owner}
  end

  test "Call consumes beyond its response buffer budget without buffering artifact and credits follow consumer" do
    {context, request, budget, owner} = context()
    parent = self()

    consumer = fn {:checkpoint, bytes} ->
      send(parent, {:consumed, byte_size(bytes), GenServer.call(owner, :state).credits})
      :ok
    end

    assert {:ok, %{"result" => "captured"}, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil} =
             Call.run(context, request, budget, <<>>, consumer)

    assert_receive {:consumed, 256, []}
    assert_receive {:consumed, 256, [256]}
    assert GenServer.call(owner, :state).credits == [256, 256]
  end

  test "missing consumer rejects before submission and failed consumer never returns credit" do
    {context, request, budget, owner} = context()
    assert {:error, %{evidence: :not_dispatched}} = Call.run(context, request, budget)
    assert GenServer.call(owner, :state).submits == 0

    assert {:ok, %{"result" => "error"}, %{file: <<>>}, %{evidence: :dispatch_uncertain}} =
             Call.run(context, request, budget, <<>>, fn _ -> {:error, :closed} end)

    assert GenServer.call(owner, :state).credits == []
  end

  test "pinned protocol-two quarantine permits explicit resolution without restoring normal work" do
    {original, capture_request, budget, _} = context()

    [proof, _] =
      Path.expand("../../native/smolbox-protocol/fixtures/capture-resolutions-v1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    health = %{
      status: :quarantined,
      protocol_major: 2,
      epoch: String.duplicate("a", 32),
      target_id: original.config.id,
      generation: original.config.domain_generation,
      package_identity: original.config.package_identity,
      package_manifest_sha256: original.config.package_manifest_sha256
    }

    owner =
      start_supervised!(
        {ControlPeer,
         %{health: health, outcome: %{"result" => "capture_resolved", "transition" => proof}}}
      )

    context = Call.pin(%{original | server: owner}, budget)
    assert %{pinned: true, epoch: epoch, server: ^owner} = context
    assert epoch == health.epoch

    request =
      Map.merge(capture_request, %{
        "operation" => "resolve_capture",
        "operation_id" => "resolve-1",
        "quiesced" => true
      })

    assert {:ok, %{"result" => "capture_resolved"}, %{file: <<>>}, nil} =
             Call.run(context, request, budget)

    assert [{^request, ^epoch}] = GenServer.call(owner, :state).submits

    assert {:error, _} =
             Call.run(
               context,
               Map.delete(request, "quiesced") |> Map.put("operation", "start"),
               budget
             )

    assert [{^request, ^epoch}] = GenServer.call(owner, :state).submits
    assert {:ok, %{status: :quarantined}} = Call.health(context, budget)
  end

  test "pinned protocol-two quarantine permits exact stage cleanup without restoring normal work" do
    {original, capture_request, budget, _} = context()

    health = %{
      status: :quarantined,
      protocol_major: 2,
      epoch: String.duplicate("a", 32),
      target_id: original.config.id,
      generation: original.config.domain_generation,
      package_identity: original.config.package_identity,
      package_manifest_sha256: original.config.package_manifest_sha256
    }

    cleanup = %{
      "schema" => 1,
      "previous" => capture_request["receipt"],
      "operation_id" => capture_request["operation_id"],
      "request" => capture_request["request"],
      "stage_sha256" => String.duplicate("d", 64)
    }

    outcome = %{"result" => "capture_staging_cleaned", "cleanup" => cleanup}
    owner = start_supervised!({ControlPeer, %{health: health, outcome: outcome}})
    context = Call.pin(%{original | server: owner}, budget)

    request =
      Map.merge(capture_request, %{"operation" => "cleanup_capture_staging", "quiesced" => true})

    assert {:ok, ^outcome, %{file: <<>>}, nil} = Call.run(context, request, budget)
    assert [{^request, epoch}] = GenServer.call(owner, :state).submits
    assert epoch == health.epoch
    assert {:error, _} = Call.run(context, Map.put(request, "quiesced", false), budget)
    assert [{^request, ^epoch}] = GenServer.call(owner, :state).submits
    assert {:ok, %{status: :quarantined}} = Call.health(context, budget)
  end

  test "pinned protocol-two quarantine permits prepared stage abort without restoring normal work" do
    {original, capture_request, budget, _} = context()

    health = %{
      status: :quarantined,
      protocol_major: 2,
      epoch: String.duplicate("a", 32),
      target_id: original.config.id,
      generation: original.config.domain_generation,
      package_identity: original.config.package_identity,
      package_manifest_sha256: original.config.package_manifest_sha256
    }

    cleanup = %{
      "schema" => 1,
      "previous" => capture_request["receipt"],
      "operation_id" => capture_request["operation_id"],
      "request" => capture_request["request"],
      "stage_sha256" => String.duplicate("d", 64)
    }

    outcome = %{"result" => "capture_staging_aborted", "cleanup" => cleanup}
    owner = start_supervised!({ControlPeer, %{health: health, outcome: outcome}})
    context = Call.pin(%{original | server: owner}, budget)

    request =
      Map.merge(capture_request, %{"operation" => "abort_capture_staging", "quiesced" => true})

    assert {:ok, ^outcome, %{file: <<>>}, nil} = Call.run(context, request, budget)
    assert [{^request, epoch}] = GenServer.call(owner, :state).submits
    assert epoch == health.epoch
    assert {:error, _} = Call.run(context, Map.put(request, "quiesced", false), budget)
    assert [{^request, ^epoch}] = GenServer.call(owner, :state).submits
    assert {:ok, %{status: :quarantined}} = Call.health(context, budget)
  end

  test "foreign domain health cannot supply a pin for explicit resolution" do
    {context, _request, budget, _} = context()

    health = %{
      status: :quarantined,
      protocol_major: 2,
      epoch: String.duplicate("a", 32),
      target_id: context.config.id,
      generation: String.duplicate("f", 32),
      package_identity: context.config.package_identity,
      package_manifest_sha256: context.config.package_manifest_sha256
    }

    owner = start_supervised!({ControlPeer, %{health: health, outcome: %{}}})
    assert %{server: nil, epoch: nil} = Call.pin(%{context | server: owner}, budget)
    assert [] == GenServer.call(owner, :state).submits
  end
end
