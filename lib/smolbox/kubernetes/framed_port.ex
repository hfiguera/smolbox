defmodule SmolBox.Kubernetes.FramedPort do
  @moduledoc false
  @max 65_536

  def exchange(executable, arguments, magic, body, budget, timeout) do
    deadline = System.monotonic_time(:millisecond) + min(timeout, budget.timeout_ms)
    exchange(executable, arguments, magic, body, budget, deadline, &legacy_decode/2)
  end

  def exchange_raw(executable, arguments, magic, body, budget, timeout, deadline),
    do:
      exchange(
        executable,
        arguments,
        magic,
        body,
        budget,
        min(deadline, System.monotonic_time(:millisecond) + min(timeout, budget.timeout_ms)),
        &{:ok, {&1, &2}}
      )

  defp exchange(executable, arguments, magic, body, budget, deadline, decoder) do
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
        do:
          receive_bytes(
            port,
            deadline,
            magic,
            <<>>,
            min(@max + 8, budget.max_response_bytes),
            decoder
          ),
        else: :error
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp receive_bytes(port, deadline, magic, bytes, max, decoder) do
    if System.monotonic_time(:millisecond) < deadline,
      do: receive_pending(port, deadline, magic, bytes, max, decoder),
      else: :error
  end

  defp receive_pending(port, deadline, magic, bytes, max, decoder) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(bytes) + byte_size(data) <= max,
          do: receive_bytes(port, deadline, magic, bytes <> data, max, decoder),
          else: :error

      {^port, {:exit_status, status}} ->
        decode(bytes, magic, decoder, status)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> :error
    end
  end

  defp decode(<<magic::binary-size(4), length::32, body::binary>>, magic, decoder, status)
       when length in 1..@max and byte_size(body) == length,
       do: decoder.(status, body)

  defp decode(_, _, _, _), do: :error
  defp legacy_decode(0, body), do: Jason.decode(body)
  defp legacy_decode(_, _), do: :error
end
