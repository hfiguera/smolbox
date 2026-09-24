defmodule Workspace.TerminalSession do
  @moduledoc "One browser consumer with bounded output and a 30-second, controller-local reconnect window."
  use GenServer, restart: :temporary
  @reconnect_ms 30_000

  def start_link({owner, execution}) do
    GenServer.start_link(__MODULE__, {owner, execution, SmolBox.Terminal},
      name: {:via, Registry, {Workspace.TerminalRegistry, execution}}
    )
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  def reconnect(key), do: reconnect_pid(via(key))
  def reconnect_pid(pid), do: GenServer.call(pid, :reconnect)
  def input(pid, bytes), do: GenServer.call(pid, {:input, bytes})
  def resize(pid, cols, rows), do: GenServer.call(pid, {:resize, cols, rows})
  def ack(pid, seq), do: GenServer.cast(pid, {:ack, self(), seq})
  def close(pid), do: GenServer.call(pid, :close)
  defp via(key), do: {:via, Registry, {Workspace.TerminalRegistry, key}}

  def init({owner, execution, api}) do
    ref = Process.monitor(owner)

    {:ok,
     %{
       owner: owner,
       monitor: ref,
       execution: execution,
       api: api,
       handle: nil,
       awaiting: nil,
       seq: 0,
       detached: nil,
       read_ref: nil
     }, {:continue, :attach}}
  end

  def handle_continue(:attach, state) do
    case state.api.attach(Workspace.Settings.runtime(), state.execution, 10_000) do
      {:ok, handle} ->
        send(state.owner, {:terminal_ready, self(), false})
        {:noreply, schedule_read(%{state | handle: handle})}

      error ->
        send(state.owner, {:terminal_closed, error})
        {:stop, :normal, state}
    end
  end

  def handle_call(:reconnect, {owner, _}, state) do
    cond do
      state.owner != nil and state.owner != owner and Process.alive?(state.owner) ->
        {:reply, {:error, :in_use}, state}

      state.detached != nil and System.monotonic_time(:millisecond) >= state.detached ->
        state.api.close(state.handle)
        {:stop, :normal, {:error, :expired}, state}

      true ->
        if state.monitor, do: Process.demonitor(state.monitor, [:flush])
        state = %{state | owner: owner, monitor: Process.monitor(owner), detached: nil}
        send(owner, {:terminal_ready, self(), true})

        state =
          case state.awaiting do
            nil -> schedule_read(state)
            {_, bytes} -> deliver(%{state | awaiting: nil}, bytes)
          end

        {:reply, {:ok, self()}, state}
    end
  end

  def handle_call({:input, bytes}, {owner, _}, %{owner: owner} = state),
    do: {:reply, state.api.input(state.handle, bytes), state}

  def handle_call({:resize, cols, rows}, {owner, _}, %{owner: owner} = state),
    do: {:reply, state.api.resize(state.handle, cols, rows), state}

  def handle_call(:close, {owner, _}, %{owner: owner} = state),
    do: {:reply, state.api.close(state.handle), state}

  def handle_call(_, _, state), do: {:reply, {:error, :not_owner}, state}

  def handle_cast({:ack, owner, seq}, %{owner: owner, awaiting: {seq, _}} = state) do
    {:noreply, schedule_read(%{state | awaiting: nil})}
  end

  def handle_cast({:ack, _, _}, state), do: {:noreply, state}

  def handle_info({:read, ref}, %{read_ref: ref, owner: owner, awaiting: nil} = state)
      when owner != nil do
    state = %{state | read_ref: nil}

    case state.api.next(state.handle, 0) do
      {:ok, {:output, bytes}} ->
        {:noreply, deliver(state, Base.encode64(bytes))}

      {:ok, {:closed, outcome}} ->
        send(owner, {:terminal_closed, outcome})
        {:stop, :normal, state}

      {:error, %{category: :expired}} ->
        {:noreply, schedule_read(state, 20)}

      error ->
        send(owner, {:terminal_closed, error})
        {:stop, :normal, state}
    end
  end

  def handle_info({:read, _}, state), do: {:noreply, state}

  def handle_info({:ack_timeout, seq}, %{awaiting: {seq, _}, owner: owner} = state)
      when owner != nil do
    # A connected but stalled consumer is still bounded; do not accumulate a transcript.
    state.api.close(state.handle)
    send(owner, {:terminal_closed, {:error, :slow_consumer}})
    {:stop, :normal, state}
  end

  def handle_info({:ack_timeout, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, owner, _}, %{owner: owner, monitor: ref} = state) do
    deadline = System.monotonic_time(:millisecond) + @reconnect_ms
    Process.send_after(self(), {:reconnect_timeout, deadline}, @reconnect_ms)
    {:noreply, %{state | owner: nil, monitor: nil, detached: deadline}}
  end

  def handle_info({:reconnect_timeout, deadline}, %{detached: deadline} = state) do
    state.api.close(state.handle)
    {:stop, :normal, state}
  end

  def handle_info({:reconnect_timeout, _}, state), do: {:noreply, state}

  defp schedule_read(state, delay \\ 0) do
    ref = make_ref()
    Process.send_after(self(), {:read, ref}, delay)
    %{state | read_ref: ref}
  end

  defp deliver(state, bytes) do
    seq = state.seq + 1
    send(state.owner, {:terminal_output, seq, bytes})
    Process.send_after(self(), {:ack_timeout, seq}, 10_000)
    %{state | awaiting: {seq, bytes}, seq: seq, read_ref: nil}
  end
end
