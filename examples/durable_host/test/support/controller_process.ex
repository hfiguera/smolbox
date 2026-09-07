defmodule SmolBox.DurableHost.ControllerProcess do
  @moduledoc false

  def run(settings_file, mode, event, phase) do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "--no-compile", "scripts/controller.exs", settings_file, mode, event, phase],
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    marker = if mode == "fault", do: "boundary:#{event}:#{phase}\n"
    deadline = System.monotonic_time(:millisecond) + 100_000

    try do
      collect(port, marker, "", deadline)
    after
      stop_owned(port)
    end
  end

  defp collect(port, marker, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        next = output <> bytes
        if byte_size(next) > 131_072, do: raise("controller output exceeded its test cap")
        marker = interrupt_at_boundary(port, marker, next)
        collect(port, marker, next, deadline)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      remaining -> raise "child controller exceeded its observation deadline: #{output}"
    end
  end

  defp interrupt_at_boundary(_port, nil, _output), do: nil

  defp interrupt_at_boundary(port, marker, output) do
    if String.contains?(output, marker) do
      {:os_pid, pid} = Port.info(port, :os_pid)
      true = String.contains?(output, "controller:#{pid}\n")
      stop_owned(port)
      nil
    else
      marker
    end
  end

  defp stop_owned(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end
  end
end
