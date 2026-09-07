defmodule SmolBox.DurableHost.BenchmarkSampler do
  @moduledoc false

  def start(runtime) do
    Task.async(fn ->
      sample(runtime, %{
        observations: 0,
        supervised_process_memory_bytes: 0,
        supervised_max_mailbox: 0,
        beam_total_bytes: 0,
        beam_binary_bytes: 0
      })
    end)
  end

  def stop(task) do
    send(task.pid, :finish)
    Task.await(task, 5000)
  end

  defp sample(runtime, peak) do
    current = snapshot(runtime)
    peak = Map.merge(peak, current, fn _key, previous, value -> max(previous, value) end)
    peak = Map.update!(peak, :observations, &(&1 + 1))

    receive do
      :finish -> peak
    after
      100 -> sample(runtime, peak)
    end
  end

  defp snapshot(runtime) do
    values =
      for pid <- subtree(runtime),
          info = Process.info(pid, [:memory, :message_queue_len]),
          info != nil,
          do: info

    %{
      supervised_process_memory_bytes: Enum.reduce(values, 0, &(&1[:memory] + &2)),
      supervised_max_mailbox: Enum.max(Enum.map(values, & &1[:message_queue_len]), fn -> 0 end),
      beam_total_bytes: :erlang.memory(:total),
      beam_binary_bytes: :erlang.memory(:binary)
    }
  end

  defp subtree(supervisor) do
    children = Supervisor.which_children(supervisor)

    [supervisor] ++
      Enum.flat_map(children, fn
        {_id, pid, :supervisor, _modules} when is_pid(pid) -> subtree(pid)
        {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
        _restarting -> []
      end)
  catch
    :exit, _restarting -> [supervisor]
  end
end
