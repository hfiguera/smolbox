defmodule Workspace.TerminalSession do
  @moduledoc "One browser consumer, bounded PTY output, no terminal reattachment or transcript storage."
  use GenServer, restart: :temporary

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  def input(pid, bytes), do: GenServer.call(pid, {:input, bytes})
  def resize(pid, cols, rows), do: GenServer.call(pid, {:resize, cols, rows})
  def ack(pid, seq), do: GenServer.cast(pid, {:ack, seq})
  def close(pid), do: GenServer.call(pid, :close)

  def init({owner, execution}), do: init({owner, execution, SmolBox.Terminal})

  def init({owner, execution, api}) do
    Process.monitor(owner)

    {:ok, %{owner: owner, execution: execution, api: api, handle: nil, awaiting: nil, seq: 0},
     {:continue, :attach}}
  end

  def handle_continue(:attach, state) do
    case state.api.attach(Workspace.Settings.runtime(), state.execution, 10_000) do
      {:ok, handle} ->
        send(state.owner, {:terminal_ready, self()})
        send(self(), :read)
        {:noreply, %{state | handle: handle}}

      error ->
        send(state.owner, {:terminal_closed, error})
        {:stop, :normal, state}
    end
  end

  def handle_call({:input, bytes}, _from, state),
    do: {:reply, state.api.input(state.handle, bytes), state}

  def handle_call({:resize, cols, rows}, _from, state),
    do: {:reply, state.api.resize(state.handle, cols, rows), state}

  def handle_call(:close, _from, state), do: {:reply, state.api.close(state.handle), state}

  def handle_cast({:ack, seq}, %{awaiting: seq} = state) do
    send(self(), :read)
    {:noreply, %{state | awaiting: nil}}
  end

  def handle_cast({:ack, _}, state), do: {:noreply, state}

  def handle_info(:read, %{awaiting: nil} = state) do
    case state.api.next(state.handle, 0) do
      {:ok, {:output, bytes}} ->
        seq = state.seq + 1
        send(state.owner, {:terminal_output, seq, Base.encode64(bytes)})
        Process.send_after(self(), {:ack_timeout, seq}, 10_000)
        {:noreply, %{state | awaiting: seq, seq: seq}}

      {:ok, {:closed, outcome}} ->
        send(state.owner, {:terminal_closed, outcome})
        {:stop, :normal, state}

      {:error, %{category: :expired}} ->
        Process.send_after(self(), :read, 20)
        {:noreply, state}

      error ->
        send(state.owner, {:terminal_closed, error})
        {:stop, :normal, state}
    end
  end

  def handle_info({:ack_timeout, seq}, %{awaiting: seq} = state) do
    state.api.close(state.handle)
    send(state.owner, {:terminal_closed, {:error, :slow_consumer}})
    {:stop, :normal, state}
  end

  def handle_info({:ack_timeout, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state) do
    if state.handle, do: state.api.close(state.handle)
    {:stop, :normal, state}
  end
end
