defmodule Workspace.TerminalSessionTest do
  use ExUnit.Case, async: true
  alias Workspace.TerminalSession

  defmodule Peer do
    def attach(_, {observer, agent}, _) do
      send(observer, {:attached, self()})
      {:ok, {observer, agent}}
    end

    def input({observer, _}, bytes), do: send_ok(observer, {:input, bytes})
    def resize({observer, _}, cols, rows), do: send_ok(observer, {:resize, cols, rows})
    def close({observer, _}), do: send_ok(observer, :connection_closed)

    def next({_, agent}, _) do
      Agent.get_and_update(agent, fn
        [head | tail] -> {{:ok, head}, tail}
        [] -> {{:error, %SmolBox.Error{category: :expired, operation: :terminal}}, []}
      end)
    end

    defp send_ok(pid, message) do
      send(pid, message)
      :ok
    end
  end

  test "forwards input and resize, waits for output acknowledgment, and reports exit" do
    {:ok, queue} =
      Agent.start_link(fn ->
        [{:output, <<0, 255>>}, {:output, "next"}, {:closed, {:ok, %{exit_code: 7}}}]
      end)

    pid = start_supervised!({TerminalSession, {self(), {self(), queue}, Peer}})
    assert_receive {:terminal_ready, ^pid, false}
    assert_receive {:terminal_output, 1, encoded}
    assert Base.decode64!(encoded) == <<0, 255>>
    assert :ok = TerminalSession.input(pid, "pwd\r")
    assert_receive {:input, "pwd\r"}
    assert :ok = TerminalSession.resize(pid, 100, 40)
    assert_receive {:resize, 100, 40}
    refute_receive {:terminal_output, 2, _}, 30
    TerminalSession.ack(pid, 1)
    assert_receive {:terminal_output, 2, _}
    TerminalSession.ack(pid, 2)
    assert_receive {:terminal_closed, {:ok, %{exit_code: 7}}}
  end

  test "a disconnected owner can resume the same attachment and pending frame" do
    observer = self()
    owner = spawn(fn -> forward(observer) end)
    {:ok, queue} = Agent.start_link(fn -> [{:output, "one"}, {:output, "two"}] end)
    pid = start_supervised!({TerminalSession, {owner, {self(), queue}, Peer}})
    assert_receive {:attached, ^pid}
    assert_receive {:forwarded, {:terminal_output, 1, first}}
    assert {:error, :in_use} = TerminalSession.reconnect_pid(pid)
    assert {:error, :not_owner} = TerminalSession.input(pid, "bad")
    assert {:error, :not_owner} = TerminalSession.close(pid)
    TerminalSession.ack(pid, 1)
    assert Agent.get(queue, & &1) == [{:output, "two"}]
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    deadline = :sys.get_state(pid).detached
    assert is_integer(deadline)
    refute_receive :connection_closed, 30
    assert {:ok, ^pid} = TerminalSession.reconnect_pid(pid)
    assert_receive {:terminal_ready, ^pid, true}
    assert_receive {:terminal_output, 2, ^first}
    refute_receive {:attached, _}, 30
    send(pid, {:ack_timeout, 1})
    send(pid, {:reconnect_timeout, deadline})
    TerminalSession.ack(pid, 1)
    refute_receive {:terminal_output, 3, _}, 30
    TerminalSession.ack(pid, 2)
    assert_receive {:terminal_output, 3, second}
    assert Base.decode64!(second) == "two"
    refute_receive :connection_closed, 30
  end

  test "reconnect expiry closes transport without replaying work" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, queue} = Agent.start_link(fn -> [] end)
    pid = start_supervised!({TerminalSession, {owner, {self(), queue}, Peer}})
    assert_receive {:attached, ^pid}
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    deadline = :sys.get_state(pid).detached
    monitor = Process.monitor(pid)
    send(pid, {:reconnect_timeout, deadline})
    assert_receive :connection_closed
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  defp forward(observer) do
    receive do
      :stop ->
        :ok

      message ->
        send(observer, {:forwarded, message})
        forward(observer)
    end
  end

  test "a late reconnect cannot revive an expired session before its timer is delivered" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    pid = start_supervised!({TerminalSession, {self(), {self(), queue}, Peer}})
    assert_receive {:terminal_ready, ^pid, false}

    :sys.replace_state(pid, fn state ->
      %{state | owner: nil, detached: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:error, :expired} = TerminalSession.reconnect_pid(pid)
    assert_receive :connection_closed
    refute_receive {:terminal_ready, _, true}, 30
  end

  test "a slow browser is disconnected rather than buffering unbounded output" do
    {:ok, queue} = Agent.start_link(fn -> [{:output, "one"}, {:output, "two"}] end)
    pid = start_supervised!({TerminalSession, {self(), {self(), queue}, Peer}})
    assert_receive {:terminal_output, 1, _}
    send(pid, {:ack_timeout, 1})
    assert_receive :connection_closed
    assert_receive {:terminal_closed, {:error, :slow_consumer}}
    assert Agent.get(queue, & &1) == [{:output, "two"}]
  end
end
