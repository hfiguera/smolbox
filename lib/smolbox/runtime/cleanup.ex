defmodule SmolBox.Runtime.Cleanup do
  @moduledoc false
  alias SmolBox.{Client, Error, Execution, Machine}
  alias SmolBox.Runtime.Session

  def run(session) do
    with {:ok, record} <- Session.claim(session) do
      cond do
        record.cleanup == :complete -> release(session, record)
        not Execution.terminal?(record) and record.state != :unknown -> {:ok, record}
        session.worker == nil -> Session.error(:unsupported_capability, :cleanup)
        record.created_machine == nil -> unverified_creation(session)
        record.cleanup_attempts >= session.config.cleanup_attempts -> exhausted(session, record)
        true -> attempt(session, record)
      end
    end
  end

  defp attempt(session, record) do
    with {:ok, started} <-
           Session.patch(session,
             cleanup: :in_progress,
             cleanup_attempts: record.cleanup_attempts + 1
           ),
         {:ok, observed} <- inspect_machine(session, started) do
      finish_observation(session, started, observed)
    else
      {:error, %Error{category: :not_found}} -> complete(session)
      {:error, error} -> retry(session, error)
    end
  end

  defp inspect_machine(session, record),
    do:
      Session.io(session, record, :cleanup, fn ->
        Client.inspect_machine(session.worker.client, record.machine_name)
      end)

  defp finish_observation(session, record, observed) do
    if record.created_machine != nil and
         Machine.same_incarnation?(record.created_machine, observed) do
      with {:ok, record} <- acknowledge_restart(session, record, observed),
           :ok <- stop(session, record, observed),
           {:ok, stopped} <- inspect_machine(session, record),
           true <-
             Machine.same_incarnation?(record.created_machine, stopped) and
               stopped.state != :running do
        retain_or_delete(session, record)
      else
        false -> retry(session, %Error{category: :cleanup, operation: :stop})
        {:error, %Error{category: :not_found}} -> complete(session)
        {:error, error} -> retry(session, error)
      end
    else
      Session.patch(session,
        cleanup: :failed,
        next_due_at_ms: Session.now(session) + 60_000,
        cleanup_attempts: session.config.cleanup_attempts,
        last_error: %Error{category: :identity_conflict, operation: :cleanup}
      )
    end
  end

  defp acknowledge_restart(session, %{evidence: :termination_confirmed}, %{state: :running}) do
    Session.patch(session,
      evidence: :unknown,
      last_error: %Error{category: :unknown, operation: :inspect, evidence: :unknown}
    )
  end

  defp acknowledge_restart(_session, record, _observed), do: {:ok, record}

  defp stop(session, record, %{state: :running}) do
    case Session.io(session, record, :cleanup, fn ->
           Client.stop(session.worker.client, record.machine_name)
         end) do
      {:ok, _stopped} -> :ok
      error -> error
    end
  end

  defp stop(_session, _record, _stopped), do: :ok

  defp retain_or_delete(session, %{state: :unknown} = record) do
    retain_until =
      Map.get(record.deadlines, :execution, record.accepted_at_ms) + record.spec.retention_ms

    if Session.now(session) < retain_until do
      Session.patch(session,
        evidence: :termination_confirmed,
        cleanup_attempts: max(record.cleanup_attempts - 1, 0),
        next_due_at_ms:
          min(retain_until, Session.now(session) + max(1000, session.config.poll_ms))
      )
    else
      with {:ok, confirmed} <- Session.patch(session, evidence: :termination_confirmed),
           do: delete(session, confirmed)
    end
  end

  defp retain_or_delete(session, record), do: delete(session, record)

  defp delete(session, record) do
    case Session.io(session, record, :cleanup, fn ->
           Client.delete(session.worker.client, record.machine_name)
         end) do
      :ok -> verify_absence(session, record)
      {:error, %Error{category: :not_found}} -> verify_absence(session, record)
      {:error, error} -> retry(session, error)
    end
  end

  defp verify_absence(session, record) do
    case inspect_machine(session, record) do
      {:error, %Error{category: :not_found}} -> complete(session)
      {:ok, _present} -> retry(session, %Error{category: :cleanup, operation: :delete})
      {:error, error} -> retry(session, error)
    end
  end

  defp complete(session) do
    with {:ok, record} <- Session.claim(session) do
      evidence = if record.state == :unknown, do: :termination_confirmed, else: record.evidence

      with {:ok, cleaned} <-
             Session.write(session, record,
               cleanup: :complete,
               absence_at_ms: record.absence_at_ms || Session.now(session),
               evidence: evidence
             ),
           do: release(session, cleaned)
    end
  end

  defp release(_session, %{reservation: nil} = record), do: {:ok, record}

  defp release(session, record),
    do:
      Session.store(session.config, :release, [
        session.key,
        Session.guard(record),
        Session.now(session)
      ])

  defp retry(session, error) do
    with {:ok, record} <- Session.claim(session) do
      status =
        if record.cleanup_attempts >= session.config.cleanup_attempts or
             Session.remaining(session, record, :cleanup) <= 0, do: :failed, else: :in_progress

      delay =
        if status == :failed,
          do: 60_000,
          else: min(5000, session.config.poll_ms * (record.cleanup_attempts + 1))

      Session.write(session, record,
        cleanup: status,
        last_error: error,
        next_due_at_ms: Session.now(session) + delay
      )
    end
  end

  defp unverified_creation(session),
    do:
      Session.patch(session,
        cleanup: :failed,
        cleanup_attempts: session.config.cleanup_attempts,
        next_due_at_ms: Session.now(session) + 60_000,
        last_error: %Error{category: :identity_conflict, operation: :create}
      )

  defp exhausted(session, record) do
    client = %{
      session.worker.client
      | worker: %{session.worker.client.worker | operation_timeout_ms: 1000}
    }

    case Client.inspect_machine(client, record.machine_name) do
      {:error, %Error{category: :not_found}} ->
        complete(session)

      _unresolved ->
        Session.patch(session, cleanup: :failed, next_due_at_ms: Session.now(session) + 60_000)
    end
  end
end
