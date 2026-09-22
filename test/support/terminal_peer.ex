defmodule SmolBox.TerminalPeer do
  @moduledoc false
  @behaviour WebSock
  @impl true
  def init(options) do
    if options[:test_pid], do: send(options[:test_pid], {:terminal_peer, self()})
    {:push, {:binary, "ready\r\n"}, options}
  end

  @impl true
  def handle_in({"exit", [opcode: :binary]}, state),
    do: {:push, {:text, ~s({"type":"exit","code":7})}, state}

  def handle_in({"sentinel", [opcode: :binary]}, state),
    do: {:push, {:text, ~s({"type":"exit","code":130})}, state}

  def handle_in({"lost", [opcode: :binary]}, state), do: {:stop, :normal, state}

  def handle_in({"noise", [opcode: :binary]}, state),
    do: {:push, {:binary, :binary.copy("a", 65_536)}, state}

  def handle_in({bytes, [opcode: :binary]}, state), do: {:push, {:binary, bytes}, state}
  def handle_in({bytes, [opcode: :text]}, state), do: {:push, {:binary, bytes}, state}
  @impl true
  def handle_info({:frames, frames}, state), do: {:push, frames, state}
  @impl true
  def terminate(_reason, _state), do: :ok
end
