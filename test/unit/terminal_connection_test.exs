defmodule SmolBox.TerminalConnectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, Terminal}
  alias SmolBox.Terminal.{Connection, Result, Server, Spec}

  defmodule PeerTransport do
    @behaviour SmolBox.Terminal.Connection.Transport

    @impl true
    def open(context, name, spec) do
      Agent.update(context.peer, &Map.put(&1, :opened, {name, spec}))
      {:ok, context, context.budget}
    end

    @impl true
    def input_cost(_state, {:input, bytes}), do: byte_size(bytes)
    def input_cost(_state, {:resize, _cols, _rows}), do: 6

    @impl true
    def send(state, command) do
      Agent.update(state.peer, &Map.update!(&1, :commands, fn old -> old ++ [command] end))
      {:ok, state}
    end

    @impl true
    def poll(state) do
      events = Agent.get_and_update(state.peer, &{&1.events, %{&1 | events: []}})
      {:ok, state, events}
    end

    @impl true
    def acknowledge(state, bytes) do
      fails =
        Agent.get_and_update(state.peer, fn peer ->
          {peer.credit_failure, %{peer | credits: peer.credits ++ [bytes]}}
        end)

      if fails,
        do: {:error, %Error{category: :transport, operation: :terminal, evidence: :unknown}},
        else: {:ok, state}
    end

    @impl true
    def close(state), do: Agent.update(state.peer, &Map.put(&1, :closed, true))
  end

  test "controller consumes semantic binary events and returns credit only on consumption" do
    {peer, handle} = session(events: [{:output, <<0, 255, 128>>}, {:output, "two"}])
    assert_receive {_, :terminal_started}
    assert Agent.get(peer, & &1.credits) == []
    assert :ok = Server.safe_call(handle, :bind)
    assert {:ok, {:output, <<0, 255, 128>>}} = Terminal.next(handle)
    assert Agent.get(peer, & &1.credits) == [3]
    assert {:ok, {:output, "two"}} = Terminal.next(handle)
    assert Agent.get(peer, & &1.credits) == [3, 3]
    assert {:error, %{category: :expired}} = Terminal.next(handle, 0)
    assert Agent.get(peer, & &1.credits) == [3, 3]
    assert :ok = Terminal.resize(handle, 100, 40)
    assert :ok = Terminal.input(handle, <<128, 0>>)
    assert Agent.get(peer, & &1.commands) == [:attach, {:resize, 100, 40}, {:input, <<128, 0>>}]
    Agent.update(peer, &%{&1 | events: [{:exit, %Result{exit_code: 7}}, :closed]})
    assert {:ok, {:closed, {:ok, %Result{exit_code: 7}}}} = Terminal.next(handle)
    assert Agent.get(peer, & &1.closed)
  end

  test "adapter-specific total input cost rejects before dispatch and keeps a single consumer" do
    {peer, handle} = session(budget: 7)
    assert :ok = Server.safe_call(handle, :bind)

    assert {:error, %{category: :authentication}} =
             Task.async(fn -> Terminal.input(handle, "foreign") end) |> Task.await()

    assert :ok = Terminal.input(handle, "xx")
    assert {:error, %{category: :output_limit}} = Terminal.resize(handle, 80, 24)
    assert {:ok, {:closed, {:error, %{category: :output_limit}}}} = Terminal.next(handle)
    assert Agent.get(peer, & &1.commands) == [:attach, {:input, "xx"}, :close]
    assert Agent.get(peer, & &1.closed)
  end

  test "credit failure preserves delivered bytes and conservatively closes the connection" do
    {peer, handle} = session(events: [{:output, "valid"}], credit_failure: true)
    assert_receive {_, :terminal_started}
    assert :ok = Server.safe_call(handle, :bind)
    assert {:ok, {:output, "valid"}} = Terminal.next(handle)

    assert {:ok, {:closed, {:error, %{category: :transport, evidence: :unknown}}}} =
             Terminal.next(handle)

    assert Agent.get(peer, & &1.credits) == [5]
    assert Agent.get(peer, & &1.closed)
  end

  test "valid output prefix survives a later protocol event and EOF alone cannot confirm Exit" do
    for events <- [[{:output, "prefix"}, {:error, :protocol}], [{:output, "prefix"}, :closed]] do
      {peer, handle} = session(events: events)
      assert :ok = Server.safe_call(handle, :bind)
      assert {:ok, {:output, "prefix"}} = Terminal.next(handle)
      assert {:ok, {:closed, {:error, %Error{}}}} = Terminal.next(handle)
      assert Agent.get(peer, & &1.closed)
    end
  end

  test "ambiguous Exit and oversized output stay uncertain through a non-HTTP adapter" do
    for events <- [[{:exit, %Result{exit_code: 124}}], [{:output, :binary.copy("x", 1025)}]] do
      {peer, handle} = session(events: events)
      assert :ok = Server.safe_call(handle, :bind)
      assert {:ok, {:closed, {:error, %Error{}}}} = Terminal.next(handle)
      assert Agent.get(peer, & &1.closed)
    end
  end

  test "opaque connection inspection does not expose transport context" do
    peer = peer([])
    context = %{peer: peer, budget: 8, secret: "private-context"}
    assert {:ok, connection} = Connection.open({PeerTransport, context}, "owned", %Spec{})
    refute inspect(connection) =~ "private-context"
    assert {:ok, _} = Connection.send(connection, {:input, "bytes"})
    Connection.close(connection)
  end

  defp session(options) do
    peer = peer(options)
    {:ok, spec} = Spec.new(max_buffer_bytes: 1024)

    assert {:ok, handle} =
             Server.start_connection(
               {PeerTransport, %{peer: peer, budget: options[:budget] || 100}},
               "owned",
               spec,
               nil
             )

    on_exit(fn -> if Process.alive?(handle.pid), do: GenServer.stop(handle.pid, :normal) end)
    {peer, handle}
  end

  defp peer(options),
    do:
      start_supervised!(
        {Agent,
         fn ->
           %{
             commands: [],
             credits: [],
             closed: false,
             events: options[:events] || [],
             credit_failure: options[:credit_failure] || false
           }
         end},
        id: make_ref()
      )
end
