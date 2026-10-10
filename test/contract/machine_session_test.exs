defmodule SmolBox.Runtime.MachineSessionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Runtime.MachineSession

  defmodule Clock do
    def now, do: Agent.get(__MODULE__, &elem(&1, 0))
    def monotonic, do: Agent.get(__MODULE__, &elem(&1, 1))
  end

  defmodule Store do
    def machine(record, :claim, _arguments), do: {:ok, record}
  end

  setup do
    start_supervised!(%{
      id: Clock,
      start: {Agent, :start_link, [fn -> {1000, 10} end, [name: Clock]]}
    })

    record = %{
      scope: "clock-test",
      id: "machine",
      operation_deadline_ms: 1200,
      spec: %{profile: %{preparation_ms: 200}}
    }

    config = %{clock: Clock, store: {Store, record}, owner: "test", lease_ms: 1000, poll_ms: 10}
    %{config: config, record: record}
  end

  for {reason, time} <- [rollback: {900, 210}, forward: {1200, 20}] do
    test "#{reason} expires machine I/O and stops its observation", %{
      config: config,
      record: record
    } do
      observer = self()

      task =
        Task.async(fn ->
          MachineSession.io(config, record, fn ->
            send(observer, {:observing, self()})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:observing, pid}
      monitor = Process.monitor(pid)
      Agent.update(Clock, fn _ -> unquote(time) end)
      assert {:error, %{category: :expired}} = Task.await(task, 1000)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    end
  end

  test "an operation without a persisted deadline still bounds elapsed preparation", %{
    config: config,
    record: record
  } do
    observer = self()

    task =
      Task.async(fn ->
        MachineSession.io(config, %{record | operation_deadline_ms: nil}, fn ->
          send(observer, :observing)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :observing
    Agent.update(Clock, fn _ -> {900, 210} end)
    assert {:error, %{category: :expired}} = Task.await(task, 1000)
  end

  test "I/O completed within its budget preserves the result", %{config: config, record: record} do
    assert {:ok, :observed} = MachineSession.io(config, record, fn -> {:ok, :observed} end)
  end
end
