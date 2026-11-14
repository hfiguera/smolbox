defmodule SmolBox.Kubernetes.FramedPort do
  @moduledoc false
  @max 65_536

  def exchange(executable, arguments, magic, body, budget, timeout) do
    deadline = System.monotonic_time(:millisecond) + min(timeout, budget.timeout_ms)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(arguments, &String.to_charlist/1)},
        {:busy_limits_port, {65_536, 131_072}},
        {:busy_limits_msgq, {65_536, 131_072}}
      ])

    try do
      if Port.command(port, <<magic::binary, byte_size(body)::32, body::binary>>, [:nosuspend]),
        do: receive_bytes(port, deadline, magic, <<>>, min(@max + 8, budget.max_response_bytes)),
        else: :error
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp receive_bytes(port, deadline, magic, bytes, max) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(bytes) + byte_size(data) <= max,
          do: receive_bytes(port, deadline, magic, bytes <> data, max),
          else: :error

      {^port, {:exit_status, 0}} ->
        decode(bytes, magic)

      {^port, {:exit_status, _}} ->
        :error
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> :error
    end
  end

  defp decode(<<magic::binary-size(4), length::32, body::binary>>, magic)
       when length in 1..@max and byte_size(body) == length,
       do: Jason.decode(body)

  defp decode(_, _), do: :error
end
