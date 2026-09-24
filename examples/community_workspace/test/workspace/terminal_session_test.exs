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
    assert_receive {:terminal_ready, ^pid}
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

  test "browser owner exit closes only the terminal transport" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, queue} = Agent.start_link(fn -> [] end)
    pid = start_supervised!({TerminalSession, {owner, {self(), queue}, Peer}})
    assert_receive {:attached, ^pid}
    ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive :connection_closed
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
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
