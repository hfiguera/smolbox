defmodule SmolBox.CI.Child do
  @moduledoc false
  use GenServer

  alias SmolBox.CI.Util

  def start_link(arguments, options \\ []),
    do: GenServer.start_link(__MODULE__, {arguments, options})

  def snapshot(child), do: GenServer.call(child, :snapshot)
  def os_pid(child), do: GenServer.call(child, :os_pid)
  def next_phase(child), do: GenServer.call(child, :next_phase)
  def send_line(child, line), do: GenServer.call(child, {:send, line <> "\n"})
  def await(child), do: GenServer.call(child, :await, :infinity)
  def stop(child), do: GenServer.call(child, :stop, :infinity)

  def execute(arguments, options \\ []) do
    {:ok, child} = start_link(arguments, options)

    try do
      await(child)
    after
      GenServer.stop(child)
    end
  end

  @impl true
  def init({arguments, options}) do
    Process.flag(:trap_exit, true)
    timeout = Keyword.get(options, :timeout, 1_200_000)
    limit = Keyword.get(options, :output_limit, 4 * 1024 * 1024)
    Util.ensure!(arguments != [] and timeout > 0 and limit > 0, "invalid child bounds")
    port = open_gated(arguments, options)
    {:os_pid, pid} = Port.info(port, :os_pid)
    # Unix BEAM ports start a new session. Verify before releasing the shell gate;
    # an unexpected platform implementation must never signal the parent's group.
    {group, 0} = System.cmd("ps", ["-p", to_string(pid), "-o", "pgid="])

    if String.trim(group) != to_string(pid) do
      Port.close(port)
      raise ArgumentError, "child has no independently owned process group"
    end

    Port.command(port, "start\n")
    timer = Process.send_after(self(), :deadline, timeout)

    {:ok,
     %{
       port: port,
       pid: pid,
       timer: timer,
       kill_timer: nil,
       started: System.monotonic_time(:millisecond),
       limit: limit,
       data: <<>>,
       pending: <<>>,
       phase_tracking: Keyword.get(options, :phases, false),
       phases: :queue.new(),
       phase_count: 0,
       failure: nil,
       exit_code: nil,
       done: false,
       waiters: []
     }}
  end

  defp open_gated(arguments, options) do
    args = ["-c", "read smolbox_start || exit 125; exec \"$@\"", "smolbox-ci" | arguments]

    env =
      Enum.map(Keyword.get(options, :env, []), fn {key, value} ->
        {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
      end)

    port_options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      args: args,
      env: env,
      cd: Keyword.get(options, :cd, File.cwd!())
    ]

    Port.open({:spawn_executable, ~c"/bin/sh"}, port_options)
  end

  @impl true
  def handle_call(:os_pid, _from, state), do: {:reply, state.pid, state}
  def handle_call(:snapshot, _from, state), do: {:reply, result(state), state}

  def handle_call(:next_phase, _from, state) do
    case :queue.out(state.phases) do
      {{:value, phase}, remaining} ->
        {:reply, {:ok, phase}, %{state | phases: remaining, phase_count: state.phase_count - 1}}

      {:empty, _} ->
        {:reply, if(state.done, do: :done, else: :empty), state}
    end
  end

  def handle_call({:send, _}, _from, %{done: true} = state),
    do: {:reply, {:error, :exited}, state}

  def handle_call({:send, bytes}, _from, state) do
    {:reply, Port.command(state.port, bytes), state}
  end

  def handle_call(:await, _from, %{done: true} = state), do: {:reply, result(state), state}
  def handle_call(:await, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}
  def handle_call(:stop, _from, %{done: true} = state), do: {:reply, result(state), state}

  def handle_call(:stop, from, state) do
    {:noreply, state |> Map.update!(:waiters, &[from | &1]) |> cancel("stopped")}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    room = max(0, state.limit + 1 - byte_size(state.data))
    kept = binary_part(bytes, 0, min(room, byte_size(bytes)))
    state = %{state | data: state.data <> kept} |> phases(kept)
    state = if byte_size(state.data) > state.limit, do: cancel(state, "output_limit"), else: state
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, finish(%{state | exit_code: code})}
  end

  def handle_info(:deadline, state), do: {:noreply, cancel(state, "deadline")}

  def handle_info(:kill, %{done: true} = state), do: {:noreply, state}

  def handle_info(:kill, state) do
    signal(state.pid, "KILL")
    if Port.info(state.port), do: Port.close(state.port)
    {:noreply, finish(state)}
  end

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  @impl true
  def terminate(_reason, %{done: true}), do: :ok
  def terminate(_reason, state), do: signal(state.pid, "KILL")

  defp cancel(%{done: true} = state, _), do: state
  defp cancel(%{kill_timer: timer} = state, _) when not is_nil(timer), do: state

  defp cancel(state, failure) do
    signal(state.pid, "TERM")
    %{state | failure: failure, kill_timer: Process.send_after(self(), :kill, 5_000)}
  end

  defp finish(%{done: true} = state), do: state

  defp finish(state) do
    # Leader exit does not establish descendant exit. Signal only the verified
    # group even when a child keeps its inherited output pipe open.
    signal(state.pid, "KILL")
    Process.cancel_timer(state.timer)
    if state.kill_timer, do: Process.cancel_timer(state.kill_timer)
    state = %{state | done: true}
    Enum.each(state.waiters, &GenServer.reply(&1, result(state)))
    %{state | waiters: []}
  end

  defp signal(pid, name) do
    System.cmd("/bin/kill", ["-" <> name, "--", "-" <> to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp phases(%{phase_tracking: false} = state, _bytes), do: state

  defp phases(state, bytes) do
    parts = :binary.split(state.pending <> bytes, "\n", [:global])
    {lines, [pending]} = Enum.split(parts, -1)
    state = Enum.reduce(lines, state, &phase/2)

    if byte_size(pending) > 65_536 do
      cancel(%{state | pending: <<>>}, "line_limit")
    else
      %{state | pending: pending}
    end
  end

  defp phase("phase:" <> _ = line, state) do
    if state.phase_count >= 128 or not String.valid?(line) do
      cancel(state, "phase_limit")
    else
      %{state | phases: :queue.in(line, state.phases), phase_count: state.phase_count + 1}
    end
  end

  defp phase(_, state), do: state

  defp result(state) do
    {state.data,
     %{
       exit_code: state.exit_code,
       failure: state.failure,
       status:
         if(state.done and state.exit_code == 0 and is_nil(state.failure),
           do: "passed",
           else: "failed"
         ),
       seconds: (System.monotonic_time(:millisecond) - state.started) / 1_000,
       captured_bytes: byte_size(state.data),
       output_sha256: Base.encode16(:crypto.hash(:sha256, state.data), case: :lower)
     }}
  end
end
