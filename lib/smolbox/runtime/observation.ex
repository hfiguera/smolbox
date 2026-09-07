defmodule SmolBox.Runtime.Observation do
  @moduledoc false
  alias SmolBox.{Client, Error, Result, Telemetry}
  alias SmolBox.Runtime.Session

  def run(session, record) do
    Telemetry.span(session.config.telemetry_table, :execution, session.key, fn ->
      observe_command(session, record)
    end)
  end

  defp observe_command(session, record) do
    observer = self()
    once = :atomics.new(1, [])
    token = make_ref()

    callback = fn
      {stream, _data} when stream in [:stdout, :stderr] ->
        if :atomics.compare_exchange(once, 1, 0, 1) == :ok, do: send(observer, {token, :started})

      _event ->
        :ok
    end

    task = Task.async(fn -> Session.safe(fn -> execute(session, record, callback) end) end)

    try do
      observe(session, record, task, token)
    after
      Task.shutdown(task, :brutal_kill)

      receive do
        {^token, :started} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp execute(session, record, callback) do
    worker = session.worker.client.worker

    client = %{
      session.worker.client
      | worker: %{
          worker
          | operation_timeout_ms:
              min(worker.operation_timeout_ms, record.spec.profile.execution_ms),
            max_response_bytes:
              min(worker.max_response_bytes, record.spec.profile.max_output_bytes * 2 + 4096)
        }
    }

    options = [max_output_bytes: record.spec.profile.max_output_bytes]

    if record.spec.command.stdin == nil,
      do:
        Client.exec_stream(
          client,
          record.machine_name,
          record.spec.command,
          options ++ [on_event: callback]
        ),
      else: Client.exec(client, record.machine_name, record.spec.command, options)
  end

  defp observe(session, record, task, token) do
    budget = Session.remaining(session, record, :execution)

    case Task.yield(task, 0) do
      {:ok, result} ->
        outcome(session, result)

      nil ->
        cond do
          record.cancel_requested_at_ms != nil -> uncertain(session, :unknown)
          budget <= 0 -> uncertain(session, :expired)
          true -> wait(session, record, task, token, min(session.config.poll_ms, budget))
        end
    end
  end

  defp wait(session, _record, task, token, timeout) do
    case Task.yield(task, timeout) do
      {:ok, result} ->
        outcome(session, result)

      nil ->
        with {:ok, current} <- progress(session, token),
             do: observe(session, current, task, token)

      _lost ->
        uncertain(session, :unknown)
    end
  end

  defp progress(session, token) do
    receive do
      {^token, :started} -> Session.patch(session, state: :running, evidence: :running_observed)
    after
      0 -> Session.claim(session)
    end
  end

  defp outcome(session, {:ok, %Result{} = result}),
    do: Session.patch(session, state: :collecting, evidence: :exited, result: result)

  defp outcome(session, {:error, %Error{exit_code: code} = error}) when is_integer(code) do
    result = %Result{exit_code: code, stdout: "", stderr: "", truncated: true}

    Session.patch(session,
      state: :collecting,
      evidence: :exited,
      result: result,
      last_error: error
    )
  end

  defp outcome(session, {:error, %Error{} = error}),
    do:
      Session.patch(session,
        state: :unknown,
        evidence: :unknown,
        last_error: %{error | evidence: :unknown}
      )

  defp outcome(session, _invalid), do: uncertain(session, :protocol)

  defp uncertain(session, category),
    do:
      Session.patch(session,
        state: :unknown,
        evidence: :unknown,
        last_error: %Error{category: category, operation: :exec_stream, evidence: :unknown}
      )
end
