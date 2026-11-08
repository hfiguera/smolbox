defmodule SmolBox.EmbeddedTerminalContractTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    Channel,
    Frame,
    JSON,
    Outbox,
    Port,
    Protocol,
    Request,
    SDKIdentity,
    TerminalContract
  }

  @fixture Path.expand(
             "../../native/smolbox-protocol/fixtures/terminal-open-request.json",
             __DIR__
           )

  test "shared open fixture preserves bounds and distinguishes approved current and older descriptors" do
    fixture = fixture()
    assert Request.valid?(fixture["operation"], fixture["budget_ms"], 2)
    refute Request.valid?(fixture["operation"], fixture["budget_ms"], 1)
    current = SDKIdentity.implemented("1.22.0", String.duplicate("a", 40))
    sdk = update_in(current, ["feature_versions"], &Map.delete(&1, "terminals"))
    refute "terminal_open" in Protocol.capabilities(sdk)
    refute Map.has_key?(Protocol.limits(2, 0, sdk), "terminals")
    future = put_in(sdk, ["feature_versions", "terminals"], 1)
    assert SDKIdentity.valid?(future)
    assert SDKIdentity.approved?(future, "1.22.0", String.duplicate("a", 40))
    assert "terminal_open" in Protocol.capabilities(future)
    assert Protocol.limits(2, 0, future)["terminals"] == TerminalContract.limits()

    refute SDKIdentity.valid?(
             update_in(future, ["feature_versions"], &Map.delete(&1, "buffered_exec"))
           )

    refute TerminalContract.spec?(Map.put(fixture["operation"]["terminal"], "extra", true))
    refute TerminalContract.action?(%{"action" => "input", "data_base64" => ""})
  end

  test "existing terminal-only descriptors keep their historical Hello and limits" do
    path = Path.expand("../../native/smolbox-protocol/fixtures/hello-v2-current.json", __DIR__)
    assert {:ok, %{"hello" => hello}} = Protocol.decode(File.read!(path), 2)
    sdk = SDKIdentity.implemented("1.22.0", hello["sdk"]["source_revision"])
    assert hello["sdk"] == sdk
    assert hello["capabilities"] == Protocol.capabilities(sdk)
    assert hello["limits"] == Protocol.limits(2, 0, sdk)
  end

  test "standalone preflight is separately negotiated and returns only zero-output readiness" do
    base = Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)

    assert {:ok, %{"hello" => hello}} =
             Protocol.decode(File.read!(Path.join(base, "hello-v2-terminal-preflight.json")), 2)

    sdk = hello["sdk"]
    assert SDKIdentity.approved?(sdk, "1.22.0", sdk["source_revision"])
    assert hello["capabilities"] == Protocol.capabilities(sdk)
    legacy = update_in(sdk, ["feature_versions"], &Map.delete(&1, "terminal_preflight"))
    refute "terminal_preflight" in Protocol.capabilities(legacy)
    assert "terminal_open" in Protocol.capabilities(legacy)
    refute SDKIdentity.valid?(update_in(sdk, ["feature_versions"], &Map.delete(&1, "terminals")))

    fixture =
      Path.join(base, "terminal-preflight-request.json") |> File.read!() |> Jason.decode!()

    request = fixture["operation"]
    assert Request.valid?(request, 30_000, 2)
    assert Request.observation?(request)
    refute Request.valid?(request, 30_001, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.valid?(Map.put(request, "terminal", %{}), 1000, 2)
    receipt = request["receipt"]

    channel =
      Channel.new(%{
        "epoch" => fixture["epoch"],
        "major" => 2,
        "minor" => 0,
        "domain" => %{
          "target_id" => receipt["target_id"],
          "generation" => receipt["domain_generation"]
        }
      })

    assert {:ok, 1, channel} = Channel.register(channel, request, 1024, 64)

    assert {:ok, channel, {1, :accepted}} =
             Channel.receive_message(
               channel,
               %{"type" => "accepted", "epoch" => fixture["epoch"], "id" => 1, "sequence" => 0}
             )

    assert :error = Channel.receive_message(channel, opened(fixture))
    assert :error = Channel.receive_message(channel, event(fixture, 1, "forbidden"))
    assert :error = Channel.terminal_control(channel, 1, 1, %{"action" => "attach"})

    assert {:ok, _, {1, {:terminal, %{"result" => "ready"}}}} =
             Channel.receive_message(
               channel,
               terminal(fixture, 1, %{"result" => "ready"})
             )
  end

  test "open attach input resize close and completion have separate correlation and evidence" do
    {fixture, channel} = accepted()
    attach = %{"action" => "attach"}
    assert :error = Channel.terminal_control(channel, 1, 1, attach)
    assert :error = Channel.receive_message(channel, event(fixture, 1, <<0, 255>>))

    opened = %{
      "type" => "terminal_opened",
      "epoch" => fixture["epoch"],
      "id" => 1,
      "sequence" => 1
    }

    assert {:ok, channel, {1, :terminal_opened}} = Channel.receive_message(channel, opened)
    assert :error = Channel.receive_message(channel, opened)
    assert {:ok, channel, true} = Channel.terminal_control(channel, 1, 1, attach)
    assert :error = Channel.terminal_control(channel, 1, 1, attach)

    assert {:ok, channel, true} =
             Channel.terminal_control(channel, 1, 2, %{
               "action" => "input",
               "data_base64" => Base.encode64(<<0, 255>>)
             })

    assert {:ok, channel, {1, {:output, :terminal, <<0, 255>>}}} =
             Channel.receive_message(channel, event(fixture, 2, <<0, 255>>))

    assert :error = Channel.acknowledge(channel, 1, 1)
    assert {:ok, channel, %{events: 1}} = Channel.acknowledge(channel, 1, 2)

    assert {:ok, channel, true} =
             Channel.terminal_control(channel, 1, 3, %{
               "action" => "resize",
               "cols" => 120,
               "rows" => 43
             })

    assert {:ok, channel, true} = Channel.terminal_control(channel, 1, 4, %{"action" => "close"})

    assert :error =
             Channel.terminal_control(channel, 1, 5, %{
               "action" => "input",
               "data_base64" => "eA=="
             })

    for {exit, collected} <- [{7, false}, {124, true}, {130, true}, {nil, true}] do
      refute Protocol.valid_outcome?(outcome(exit, collected, 2), 2)
    end

    result = outcome(7, true, 2)

    assert Protocol.valid_outcome?(
             %{
               result
               | "completion" => "native_error",
                 "dispatch" => "not_dispatched",
                 "observed_exit" => nil,
                 "output_bytes" => 0
             },
             2
           )

    refute Protocol.valid_outcome?(result, 1)

    assert :error =
             Channel.receive_message(
               channel,
               terminal(fixture, 3, %{result | "output_bytes" => 1})
             )

    assert {:ok, channel, {1, {:terminal, ^result}}} =
             Channel.receive_message(channel, terminal(fixture, 3, result))

    assert {:ok, channel} = Channel.retire(channel, 1)
    assert {:ok, _channel, false} = Channel.terminal_control(channel, 1, 5, attach)
    assert :error = Channel.terminal_control(channel, 2, 1, attach)
  end

  test "terminal output has bounded outstanding credit without the command lifetime event cap" do
    {fixture, channel} = accepted()

    opened = %{
      "type" => "terminal_opened",
      "epoch" => fixture["epoch"],
      "id" => 1,
      "sequence" => 1
    }

    {:ok, channel, _} = Channel.receive_message(channel, opened)

    channel =
      Enum.reduce(2..65_541, channel, fn sequence, channel ->
        message = event(fixture, sequence, <<255>>)
        assert {:ok, ^message} = Protocol.decode(Jason.encode!(message), 2)
        assert {:ok, channel, _} = Channel.receive_message(channel, message)
        assert {:ok, channel, %{events: 1}} = Channel.acknowledge(channel, 1, 1)
        channel
      end)

    assert channel.queued_bytes == 0 and channel.queued_events == 0
    result = outcome(7, true, 65_540)

    assert {:ok, _channel, _} =
             Channel.receive_message(channel, terminal(fixture, 65_542, result))
  end

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  test "Port controls bind the observer and reserve only two ordered input slots" do
    {fixture, channel} = accepted()
    {handle, state} = port_state(fixture, channel)
    attach = {:terminal_control, handle, %{"action" => "attach"}}
    assert {:reply, {:error, _}, ^state} = Port.handle_call(attach, {self(), nil}, state)
    state = receive_port(state, opened(fixture))
    assert_receive {:smolbox_embedded, ^handle, :terminal_opened}
    assert {:reply, {:error, _}, ^state} = Port.handle_call(attach, {nil, nil}, state)
    assert {:reply, :ok, state} = Port.handle_call(attach, {self(), nil}, state)

    assert {:reply, :ok, state} =
             Port.handle_call(
               {:terminal_control, handle, %{"action" => "input", "data_base64" => "AP8="}},
               {self(), nil},
               state
             )

    resize = {:terminal_control, handle, %{"action" => "resize", "cols" => 120, "rows" => 43}}
    assert {:reply, {:error, _}, ^state} = Port.handle_call(resize, {self(), nil}, state)
    assert state.channel.pending[1].terminal_control == 2
    assert state.channel.pending[1].terminal_input == 2
    assert {:ok, %{message: %{"sequence" => 1, "epoch" => epoch}}} = Outbox.next(state.outbox)
    assert epoch == fixture["epoch"]
    state = %{state | outbox: Outbox.pop(state.outbox)}
    assert {:reply, :ok, state} = Port.handle_call(resize, {self(), nil}, state)
    assert state.channel.pending[1].terminal_control == 3
    assert state.channel.pending[1].terminal_input == 6
    assert Enum.map(:queue.to_list(state.outbox.data), & &1.message["sequence"]) == [2, 3]

    assert {:ok, queue} =
             Outbox.put(state.outbox, %{kind: :cancel, id: 1, message: %{"type" => "cancel"}}, 0)

    assert {:ok, %{kind: :cancel}} = Outbox.next(queue)
  end

  test "Port returns whole consumption credit and bounds each frame instead of lifetime transcript" do
    {fixture, channel} = accepted()
    {handle, state} = port_state(fixture, channel)
    state = receive_port(state, opened(fixture))
    assert_receive {:smolbox_embedded, ^handle, :terminal_opened}

    state =
      Enum.reduce(2..101, state, fn sequence, state ->
        state = receive_port(state, event(fixture, sequence, <<0, 255, 128>>))
        assert_receive {:smolbox_embedded, ^handle, {:output, :terminal, <<0, 255, 128>>}}

        assert {:reply, {:error, _}, ^state} =
                 Port.handle_call({:acknowledge, handle, 1}, {self(), nil}, state)

        assert {:reply, :ok, state} =
                 Port.handle_call({:acknowledge, handle, 3}, {self(), nil}, state)

        assert {:ok, %{kind: :credit, message: %{"decoded_bytes" => 3, "events" => 1}}} =
                 Outbox.next(state.outbox)

        %{state | outbox: Outbox.pop(state.outbox)}
      end)

    assert state.records[1].error == nil
    assert state.records[1].response_bytes < state.records[1].response_limit
    assert state.channel.pending[1].output_bytes == 300
    assert state.channel.queued_bytes == 0
  end

  # A negotiated terminal channel is injected only into pure callback state.
  # This exercises routing without approving a package or native capability.
  defp port_state(fixture, channel) do
    handle = make_ref()

    record = %{
      handle: handle,
      observer: self(),
      caller: self(),
      operation: fixture["operation"],
      notified: false,
      error: nil,
      sent: true,
      owed: 0,
      response_bytes: 0,
      response_limit: 512,
      deadline: System.monotonic_time(:millisecond) + 5000
    }

    {handle,
     %{
       channel: channel,
       records: %{1 => record},
       handles: %{handle => 1},
       outbox: %Outbox{},
       closing: false,
       flush_timer: :unused,
       port: :model,
       frame: %Frame{},
       status: :ready,
       protocol_major: 2,
       config: %{limits: %{send_queue_bytes: 1_048_576}}
     }}
  end

  defp opened(fixture),
    do: %{"type" => "terminal_opened", "epoch" => fixture["epoch"], "id" => 1, "sequence" => 1}

  defp receive_port(state, message) do
    {:ok, encoded} = JSON.encode(message)
    {:noreply, state} = Port.handle_info({state.port, {:data, encoded}}, state)
    state
  end

  defp accepted do
    fixture = fixture()
    receipt = fixture["operation"]["receipt"]

    channel =
      Channel.new(%{
        "epoch" => fixture["epoch"],
        "major" => 2,
        "minor" => 0,
        "domain" => %{
          "target_id" => receipt["target_id"],
          "generation" => receipt["domain_generation"]
        }
      })

    assert {:ok, 1, channel} = Channel.register(channel, fixture["operation"], 1024, 64)

    assert {:ok, channel, {1, :accepted}} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => fixture["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    {fixture, channel}
  end

  defp event(fixture, seq, bytes),
    do: %{
      "type" => "event",
      "epoch" => fixture["epoch"],
      "id" => 1,
      "sequence" => seq,
      "event" => %{"stream" => "terminal", "data_base64" => Base.encode64(bytes)}
    }

  defp outcome(exit, collected, bytes),
    do: %{
      "result" => "terminal",
      "completion" => "exited",
      "dispatch" => "may_have_dispatched",
      "observed_exit" => exit,
      "worker_collected" => collected,
      "output_bytes" => bytes
    }

  defp terminal(fixture, sequence, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => fixture["epoch"],
      "id" => 1,
      "sequence" => sequence,
      "outcome" => outcome
    }
end
