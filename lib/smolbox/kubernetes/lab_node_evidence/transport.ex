defmodule SmolBox.Kubernetes.LabNodeEvidence.Transport do
  @moduledoc false
  alias SmolBox.Kubernetes.Operation

  @command "~/smolbox-kubernetes-lab/lab.sh ssh sudo /usr/bin/python3 /usr/local/lib/smolbox-kubernetes/node-history/node_inspector.py inspect"
  @max 65_536

  def request(context, body, budget) when byte_size(body) in 1..@max do
    if byte_size(body) + 8 <= budget.max_request_bytes,
      do: exchange(context, body, budget),
      else: :error
  end

  def request(_, _, _), do: :error

  defp exchange(context, body, budget) do
    deadline = Operation.now() + min(30_000, budget.timeout_ms)

    port =
      Port.open({:spawn_executable, String.to_charlist(context.ssh_executable)}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(arguments(context.ssh_host), &String.to_charlist/1)},
        {:busy_limits_port, {65_536, 131_072}},
        {:busy_limits_msgq, {65_536, 131_072}}
      ])

    try do
      if Port.command(port, <<"SBH1", byte_size(body)::32, body::binary>>, [:nosuspend]),
        do: receive_bytes(port, deadline, <<>>, min(@max + 8, budget.max_response_bytes)),
        else: :error
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp arguments(host),
    do: [
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "ForwardAgent=no",
      "-o",
      "ClearAllForwardings=yes",
      "-o",
      "ConnectTimeout=5",
      "-o",
      "ServerAliveInterval=5",
      "-o",
      "ServerAliveCountMax=1",
      host,
      @command
    ]

  defp receive_bytes(port, deadline, bytes, max_bytes) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(bytes) + byte_size(data) <= max_bytes,
          do: receive_bytes(port, deadline, bytes <> data, max_bytes),
          else: :error

      {^port, {:exit_status, 0}} ->
        decode(bytes)

      {^port, {:exit_status, _}} ->
        :error
    after
      max(0, deadline - Operation.now()) -> :error
    end
  end

  defp decode(<<"SBH1", length::32, body::binary>>)
       when length in 1..@max and byte_size(body) == length,
       do: Jason.decode(body)

  defp decode(_), do: :error
end
