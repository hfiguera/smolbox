defmodule SmolBox.TelemetryDispatcherTest do
  use ExUnit.Case, async: false
  alias SmolBox.Telemetry.Dispatcher

  @event [:smolbox, :test, :notification]

  setup do
    table = Dispatcher.table()
    dispatcher = start_supervised!({Dispatcher, table: table, max_pending: 2, timeout_ms: 100})
    %{table: table, dispatcher: dispatcher}
  end

  test "absent and stopped endpoints are optional, not execution failures" do
    assert :ok = Dispatcher.offer(nil, {@event, %{}, %{}})
    assert %{available: false} = Dispatcher.stats(nil)
    table = Dispatcher.table()
    assert :ok = Dispatcher.offer(table, {@event, %{}, %{}})
    assert %{available: false} = Dispatcher.stats(table)
    :ets.delete(table)
    assert :ok = Dispatcher.offer(table, {@event, %{}, %{}})
    assert %{available: false} = Dispatcher.stats(table)
  end

  test "a blocked handler has bounded backlog, nonblocking producers and a deadline", context do
    attach(:block)
    Dispatcher.offer(context.table, {@event, %{}, %{sequence: 1}})
    assert_receive {:handler, first, %{sequence: 1}}
    monitor = Process.monitor(first)
    Dispatcher.offer(context.table, {@event, %{}, %{sequence: 2}})
    started = System.monotonic_time(:millisecond)

    for number <- 1..1000 do
      Dispatcher.offer(context.table, {@event, %{}, %{sequence: number + 2}})
    end

    assert System.monotonic_time(:millisecond) - started < 100
    assert %{pending: 2, dropped: 1000, limit: 2} = Dispatcher.stats(context.table)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 1000
    assert_receive {:handler, _second, %{sequence: 2}}, 1000
    stats = eventually(context.table, &(&1.pending == 0))
    assert stats.timed_out == 2 and stats.processed == 0 and stats.dropped == 1000
    assert Process.alive?(context.dispatcher)
    assert {:message_queue_len, length} = Process.info(context.dispatcher, :message_queue_len)
    assert length <= 4
  end

  test "a killed delivery process does not kill the dispatcher or poison later events", context do
    id = attach(:kill)
    Dispatcher.offer(context.table, {@event, %{}, %{}})
    assert_receive {:handler, _pid, %{}}
    assert eventually(context.table, &(&1.dropped == 1)).pending == 0
    :ok = :telemetry.detach(id)
    attach(:forward)
    Dispatcher.offer(context.table, {@event, %{}, %{after_failure: true}})
    assert_receive {:handler, _pid, %{after_failure: true}}
    assert eventually(context.table, &(&1.processed == 1)).available
    assert Process.alive?(context.dispatcher)
  end

  test "dispatcher death terminates its active handler and restart uses fresh credits", context do
    attach(:block)
    before = Dispatcher.stats(context.table)
    Dispatcher.offer(context.table, {@event, %{}, %{}})
    assert_receive {:handler, handler, %{}}
    monitor = Process.monitor(handler)
    Process.exit(context.dispatcher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^handler, :killed}, 1000
    stats = eventually(context.table, &(&1.available and &1.epoch != before.epoch))
    assert stats.pending == 0
  end

  test "idle recovery retires a producer's abandoned credit and discards its late event",
       context do
    attach(:forward)
    [{:endpoint, _pid, counters, _limit, epoch}] = :ets.lookup(context.table, :endpoint)
    :atomics.add(counters, 1, 1)
    stats = eventually(context.table, &(&1.epoch != epoch))
    assert stats.pending == 0
    send(context.dispatcher, {:event, counters, {@event, %{}, %{retired: true}}})
    Dispatcher.offer(context.table, {@event, %{}, %{current: true}})
    assert_receive {:handler, _pid, %{current: true}}
    refute_receive {:handler, _pid, %{retired: true}}, 50
    assert eventually(context.table, &(&1.processed == 1)).pending == 0
  end

  def delivery(_event, _measurements, metadata, {observer, mode}) do
    send(observer, {:handler, self(), metadata})

    case mode do
      :block ->
        receive do
          :release -> :ok
        end

      :kill ->
        Process.exit(self(), :kill)

      :forward ->
        :ok
    end
  end

  defp attach(mode) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.delivery/4, {self(), mode})
    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  defp eventually(table, predicate, attempts \\ 300)
  defp eventually(_table, _predicate, 0), do: flunk("notification state did not settle")

  defp eventually(table, predicate, attempts) do
    stats = Dispatcher.stats(table)

    if predicate.(stats) do
      stats
    else
      receive do
      after
        10 -> eventually(table, predicate, attempts - 1)
      end
    end
  end
end
