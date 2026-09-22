defmodule SmolBox.Runtime.TerminalObservation do
  @moduledoc false
  alias SmolBox.{Client, Error}
  alias SmolBox.Runtime.Session
  alias SmolBox.Terminal.{Result, Server}

  def run(session, record) do
    Server.retire_closed(session.config.terminal_table, session.config.max_active)
    observer = self()

    task =
      Task.async(fn ->
        with {:ok, client} <-
               Client.terminal_preflight(
                 session.worker.client,
                 record.machine_name,
                 record.spec.command
               ),
             do: Server.start(client, record.machine_name, record.spec.command, nil, observer)
      end)

    try do
      case opening(session, record, task) do
        {:ok, handle} -> connected(session, record, handle)
        {:error, error} -> outcome(session, {:error, error})
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp connected(session, record, handle) do
    :ok = Server.safe_call(handle, {:register, session.config.terminal_table, session.key})
    monitor = Process.monitor(handle.pid)

    try do
      observe(session, record, handle)
    after
      Process.demonitor(monitor, [:flush])
      Server.safe_call(handle, {:shutdown, :terminal})
    end
  end

  defp opening(session, record, task) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        result

      nil ->
        opening_wait(session, record, task)

      _lost ->
        {:error, %Error{category: :unknown, operation: :terminal}}
    end
  end

  defp opening_wait(session, record, task) do
    if operation = stop_operation(session, record) do
      stopped(operation)
    else
      timeout =
        min(session.config.poll_ms, max(1, Session.remaining(session, record, :execution)))

      opening_result(Task.yield(task, timeout), session, task)
    end
  end

  defp opening_result({:ok, result}, _session, _task), do: result

  defp opening_result(nil, session, task),
    do: with({:ok, current} <- Session.claim(session), do: opening(session, current, task))

  defp opening_result(_lost, _session, _task),
    do: {:error, %Error{category: :unknown, operation: :terminal}}

  defp observe(session, record, handle) do
    if operation = stop_operation(session, record) do
      Server.safe_call(handle, {:shutdown, operation})
      outcome(session, stopped(operation))
    else
      wait(session, record, handle)
    end
  end

  defp wait(session, record, %{token: token, pid: pid} = handle) do
    receive do
      {:DOWN, _ref, :process, ^pid, _reason} ->
        outcome(session, {:error, %Error{category: :unknown, operation: :terminal}})

      {^token, :terminal_outcome, result} ->
        outcome(session, result)

      {^token, :terminal_started} ->
        with {:ok, current} <-
               Session.patch(session, state: :running, evidence: :running_observed),
             do: observe(session, current, handle)
    after
      min(session.config.poll_ms, max(1, Session.remaining(session, record, :execution))) ->
        with {:ok, current} <- Session.claim(session), do: observe(session, current, handle)
    end
  end

  defp stop_operation(session, record) do
    cond do
      record.cancel_requested_at_ms != nil -> :cancel
      Session.remaining(session, record, :execution) <= 0 -> :terminal_session
      true -> nil
    end
  end

  defp stopped(operation) do
    category = if operation == :terminal_session, do: :expired, else: :unknown
    {:error, %Error{category: category, operation: operation}}
  end

  defp outcome(session, {:ok, %Result{} = result}),
    do: Session.patch(session, state: :collecting, evidence: :exited, result: result)

  defp outcome(session, {:error, %Error{} = error}),
    do:
      Session.patch(session,
        state: :unknown,
        evidence: :unknown,
        last_error: %{error | evidence: :unknown}
      )

  defp outcome(session, _invalid),
    do: outcome(session, {:error, %Error{category: :protocol, operation: :terminal}})
end
