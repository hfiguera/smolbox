defmodule SmolBox.Telemetry.Dispatcher do
  @moduledoc false
  use GenServer

  @type table :: :ets.tid()

  @spec table() :: table()
  def table, do: :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec offer(table() | nil, {list(atom()), map(), map()}) :: :ok
  def offer(nil, _event), do: :ok

  def offer(table, event) do
    case :ets.lookup(table, :endpoint) do
      [{:endpoint, pid, counters, limit, _epoch}] ->
        if :atomics.add_get(counters, 1, 1) <= limit do
          send(pid, {:event, counters, event})
        else
          :atomics.sub(counters, 1, 1)
          :atomics.add(counters, 3, 1)
        end

      [] ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec stats(table() | nil) :: map()
  def stats(nil), do: %{available: false}

  def stats(table) do
    case :ets.lookup(table, :endpoint) do
      [{:endpoint, pid, counters, limit, epoch}] ->
        %{
          available: Process.alive?(pid),
          epoch: epoch,
          limit: limit,
          pending: :atomics.get(counters, 1),
          processed: :atomics.get(counters, 2),
          dropped: :atomics.get(counters, 3),
          timed_out: :atomics.get(counters, 4)
        }

      [] ->
        %{available: false}
    end
  rescue
    ArgumentError -> %{available: false}
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      table: Keyword.fetch!(options, :table),
      limit: Keyword.fetch!(options, :max_pending),
      timeout: Keyword.fetch!(options, :timeout_ms),
      metadata: Keyword.get(options, :metadata, %{}),
      counters: nil,
      idle_credit_probe: false,
      active: nil,
      queue: :queue.new()
    }

    Process.send_after(self(), :sweep, 1000)
    {:ok, renew(state)}
  end

  @impl GenServer
  def handle_info({:event, counters, event}, %{counters: counters} = state),
    do:
      {:noreply,
       dispatch(%{state | queue: :queue.in(event, state.queue), idle_credit_probe: false})}

  # An idle sweep can retire a credit reserved by a producer that died before
  # sending. Late messages from that epoch are optional observations and dropped.
  def handle_info({:event, _retired, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{active: active} = state)
      when is_map(active) and active.reference == reference do
    Process.cancel_timer(active.timer)
    :atomics.sub(state.counters, 1, 1)

    unless active.timed_out do
      counter = if reason == :normal, do: 2, else: 3
      :atomics.add(state.counters, counter, 1)
    end

    {:noreply, dispatch(%{state | active: nil})}
  end

  def handle_info({:deadline, reference}, %{active: active} = state)
      when is_map(active) and active.reference == reference do
    Process.exit(active.pid, :kill)
    :atomics.add(state.counters, 4, 1)
    {:noreply, %{state | active: %{active | timed_out: true}}}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, 1000)

    orphaned =
      state.active == nil and :queue.is_empty(state.queue) and
        :atomics.get(state.counters, 1) > 0

    state =
      if orphaned and state.idle_credit_probe,
        do: renew(state),
        else: %{state | idle_credit_probe: orphaned}

    {:noreply, state}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{active: active}) do
    if active, do: Process.exit(active.pid, :kill)
    :ok
  end

  defp dispatch(%{active: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {name, measurements, metadata}}, queue} ->
        metadata = Map.merge(metadata, state.metadata)

        {pid, reference} =
          :erlang.spawn_opt(
            fn -> :telemetry.execute(name, measurements, metadata) end,
            [:link, :monitor]
          )

        timer = Process.send_after(self(), {:deadline, reference}, state.timeout)
        active = %{pid: pid, reference: reference, timer: timer, timed_out: false}
        %{state | queue: queue, active: active}

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp renew(state) do
    counters = :atomics.new(4, [])
    epoch = System.unique_integer([:positive, :monotonic])
    :ets.insert(state.table, {:endpoint, self(), counters, state.limit, epoch})
    %{state | counters: counters, idle_credit_probe: false}
  end
end
