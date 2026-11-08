defmodule SmolBox.TerminalEmbeddedConnectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Budget
  alias SmolBox.{Error, Terminal}
  alias SmolBox.Terminal.{Connection, Result, Server, Spec}
  alias SmolBox.Terminal.Connection.Embedded
  alias SmolBox.Terminal.Connection.Embedded.Source

  defmodule Peer do
    def health(owner, timeout) do
      Agent.get_and_update(owner, fn peer ->
        {{:ok, peer.health}, %{peer | timeouts: [timeout | peer.timeouts]}}
      end)
    end

    def submit(owner, request, budget, observer, epoch, timeout) do
      Agent.get_and_update(owner, fn peer ->
        if epoch == peer.health.epoch and not peer.stale do
          handle = make_ref()
          Kernel.send(observer, {:smolbox_embedded, handle, :accepted})
          Kernel.send(observer, {:smolbox_embedded, handle, :terminal_opened})

          {{:ok, handle},
           %{
             peer
             | observer: observer,
               handle: handle,
               request: request,
               budget: budget,
               timeouts: [timeout | peer.timeouts]
           }}
        else
          {{:error,
            %Error{category: :identity_conflict, operation: :terminal, evidence: :not_dispatched}},
           peer}
        end
      end)
    end

    def terminal_control(owner, _handle, control, timeout) do
      Agent.update(
        owner,
        &%{&1 | controls: &1.controls ++ [control], timeouts: [timeout | &1.timeouts]}
      )

      :ok
    end

    def acknowledge(owner, _handle, bytes, timeout) do
      Agent.update(
        owner,
        &%{&1 | credits: &1.credits ++ [bytes], timeouts: [timeout | &1.timeouts]}
      )

      :ok
    end

    def cancel(owner, _handle, timeout) do
      Agent.update(owner, &%{&1 | cancelled: true, timeouts: [timeout | &1.timeouts]})
      :ok
    end
  end

  test "native asynchronous bytes survive the mailbox and credit follows consumption" do
    {peer, source} = source()
    {:ok, handle} = Server.start_connection({Embedded, source}, "owned", source.spec, nil)
    on_exit(fn -> if Process.alive?(handle.pid), do: GenServer.stop(handle.pid, :normal) end)
    publish(peer, {:output, :terminal, <<0, 255, 128>>})
    assert_receive {_, :terminal_started}, 1000
    assert Agent.get(peer, & &1.credits) == []
    assert :ok = Server.safe_call(handle, :bind)
    assert :ok = Server.safe_call(handle, :bind)
    assert {:ok, {:output, <<0, 255, 128>>}} = Terminal.next(handle)
    assert Agent.get(peer, & &1.credits) == [3]
    assert :ok = Terminal.input(handle, <<255, 0>>)
    assert :ok = Terminal.resize(handle, 120, 43)
    assert :ok = Terminal.close(handle)

    assert Enum.map(Agent.get(peer, & &1.controls), & &1["action"]) ==
             ~w(attach input resize close)

    publish(peer, {:terminal, outcome(7, true, 3), nil})
    assert {:ok, {:closed, {:ok, %Result{exit_code: 7}}}} = Terminal.next(handle)
    refute Agent.get(peer, & &1.cancelled)
    assert Enum.all?(Agent.get(peer, & &1.timeouts), &(&1 in 1..1000))
  end

  test "prebound native consumer attaches before input and EOF cannot replace collection" do
    {peer, source} = source()
    {:ok, handle} = Server.start_connection({Embedded, source}, "owned", source.spec, self())
    on_exit(fn -> if Process.alive?(handle.pid), do: GenServer.stop(handle.pid, :normal) end)
    assert [%{"action" => "attach"}] = Agent.get(peer, & &1.controls)
    publish(peer, {:output, :terminal, "prefix"})
    # Observer notifications are intentionally suppressed when it is also the
    # consumer. This call orders the earlier message before the next outcome.
    assert :ok = Server.safe_call(handle, :bind)
    publish(peer, {:terminal, outcome(7, false, 6), nil})
    assert {:ok, {:output, "prefix"}} = Terminal.next(handle)

    assert {:ok, {:closed, {:error, %Error{evidence: :unknown, exit_code: 7}}}} =
             Terminal.next(handle)

    assert Agent.get(peer, & &1.cancelled)
  end

  test "native connection rejects partial credit and stale admission without replay" do
    {peer, source} = source()
    {:ok, connection} = Connection.open({Embedded, source}, "owned", source.spec)
    state = Agent.get(peer, & &1)

    {:ok, connection, [{:output, <<0, 255>>}]} =
      Connection.handle_message(
        connection,
        {:smolbox_embedded, state.handle, {:output, :terminal, <<0, 255>>}}
      )

    assert {:error, %Error{}} = Connection.acknowledge(connection, 1)
    assert Agent.get(peer, & &1.credits) == []
    assert {:ok, connection} = Connection.acknowledge(connection, 2)
    Connection.close(connection)
    Agent.update(peer, &%{&1 | stale: true, handle: nil})

    assert {:error, %Error{category: :identity_conflict}} =
             Connection.open({Embedded, source}, "owned", source.spec)

    assert Agent.get(peer, & &1.handle) == nil
  end

  test "synthetic owner loss and malformed completion remain conservative" do
    {peer, source} = source()
    {:ok, state, _} = Embedded.open(source, "owned", source.spec)

    assert {:error, %Error{evidence: :unknown}} =
             Embedded.handle_message(state, {:DOWN, state.monitor, :process, peer, :model_loss})

    assert {:error, %Error{evidence: :unknown}} =
             Embedded.handle_message(
               state,
               {:smolbox_embedded, state.handle, {:terminal, nil, nil}}
             )

    assert :ignore =
             Embedded.handle_message(state, {:smolbox_embedded, make_ref(), :terminal_opened})

    Embedded.close(state)

    assert {:error, %Error{}} =
             Embedded.open(
               %{source | deadline: System.monotonic_time(:millisecond) - 1},
               "owned",
               source.spec
             )
  end

  defp publish(peer, event) do
    %{observer: observer, handle: handle} = Agent.get(peer, & &1)
    send(observer, {:smolbox_embedded, handle, event})
  end

  defp outcome(exit, collected, bytes),
    do: %{
      "result" => "terminal",
      "completion" => "exited",
      "dispatch" => "may_have_dispatched",
      "observed_exit" => exit,
      "worker_collected" => collected,
      "output_bytes" => bytes
    }

  # Internal prepared sources are injected into a non-VM peer. Production
  # source/4 remains gated by the currently unadvertised terminal capability.
  defp source do
    epoch = String.duplicate("a", 32)

    binding = %{
      id: "test",
      domain_generation: "generation",
      package_identity: %{},
      package_manifest_sha256: "digest"
    }

    health = %{
      status: :ready,
      epoch: epoch,
      target_id: binding.id,
      generation: binding.domain_generation,
      package_identity: binding.package_identity,
      package_manifest_sha256: binding.package_manifest_sha256
    }

    peer =
      start_supervised!(
        {Agent,
         fn ->
           %{
             health: health,
             stale: false,
             observer: nil,
             handle: nil,
             request: nil,
             budget: nil,
             controls: [],
             credits: [],
             cancelled: false,
             timeouts: []
           }
         end},
        id: make_ref()
      )

    {:ok, spec} = Spec.new(max_buffer_bytes: 1024, session_ms: 5000, idle_ms: 5000)

    source = %Source{
      owner: peer,
      bridge: Peer,
      epoch: epoch,
      binding: binding,
      request: %{
        "operation" => "terminal_open",
        "terminal" => %{"total_input_bytes" => 1_048_576}
      },
      budget: %Budget{
        timeout_ms: 5000,
        max_request_bytes: 1_048_576,
        max_response_bytes: 1_048_576
      },
      name: "owned",
      spec: spec,
      deadline: System.monotonic_time(:millisecond) + 5000
    }

    {peer, source}
  end
end
