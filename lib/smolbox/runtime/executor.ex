defmodule SmolBox.Runtime.Executor do
  @moduledoc false
  alias SmolBox.{Client, Error, Execution, Identity, Machine, Profile}
  alias SmolBox.Runtime.{Cleanup, Files, Observation, Session, WorkerConfig}

  def run(config, key, eligible) do
    Session.safe(fn ->
      with {:ok, record} <- Session.store(config, :fetch, [key]),
           session = Session.new(config, record),
           {:ok, claimed} <- Session.claim(session),
           {:ok, handled} <- route(session, claimed, eligible) do
        Cleanup.run(Session.new(config, handled))
      end
    end)
  end

  defp route(session, %{state: :accepted} = record, eligible),
    do: admit(session, record, eligible)

  defp route(session, %{state: :preparing}, _eligible),
    do: fail_preparation(session, %Error{category: :unknown, operation: :create})

  defp route(session, %{state: :ready} = record, _eligible), do: dispatch(session, record)

  defp route(session, %{state: state}, _eligible)
       when state in [:dispatching, :running, :cancelling],
       do:
         Session.patch(session,
           state: :unknown,
           evidence: :unknown,
           last_error: %Error{category: :unknown, operation: :exec_stream, evidence: :unknown}
         )

  defp route(session, %{state: :collecting} = record, _eligible),
    do: Files.collect(session, record)

  defp route(_session, record, _eligible), do: {:ok, record}

  defp admit(session, record, eligible) do
    cond do
      record.cancel_requested_at_ms != nil ->
        Session.patch(session, state: :cancelled, cleanup: :complete)

      Execution.expired?(record, Session.now(session)) ->
        Session.patch(session, state: :expired, cleanup: :complete)

      true ->
        reserve(session, record, eligible)
    end
  end

  defp reserve(session, record, eligible) do
    workers =
      Enum.filter(session.config.workers, fn worker ->
        worker.client.worker.id in eligible and WorkerConfig.supports?(worker, record.spec)
      end)

    result =
      Enum.reduce_while(workers, Session.error(:admission_exhausted, :reservation), fn worker,
                                                                                       _previous ->
        {:ok, name} = Identity.machine_name(session.config.namespace)

        reserved =
          Session.store(session.config, :reserve, [
            session.key,
            Session.guard(record),
            {worker.client.worker.id, name, worker.capacity},
            Session.now(session)
          ])

        case reserved do
          {:ok, next} -> {:halt, {:ok, worker, next}}
          {:error, %Error{category: :admission_exhausted}} = error -> {:cont, error}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, worker, next} ->
        prepare(%{session | worker: worker}, next)

      {:error, %Error{category: :admission_exhausted}} ->
        Session.patch(session, next_due_at_ms: Session.now(session) + session.config.poll_ms)

      error ->
        error
    end
  end

  defp prepare(session, record) do
    {:ok, spec} =
      Profile.machine(
        record.spec.profile,
        record.machine_name,
        WorkerConfig.artifact_path(session.worker, record.spec)
      )

    result =
      with {:ok, created} <-
             Session.io(session, record, :preparation, fn ->
               Client.create(session.worker.client, spec)
             end),
           {:ok, saved} <- Session.patch(session, created_machine: created),
           {:ok, started} <-
             Session.io(session, saved, :preparation, fn ->
               Client.start(session.worker.client, saved.machine_name)
             end),
           true <- Machine.same_incarnation?(created, started) and started.state == :running,
           :ok <- Files.stage(session, saved),
           {:ok, ready} <- Session.patch(session, state: :ready) do
        dispatch(session, ready)
      end

    case result do
      {:ok, _record} = ok -> ok
      {:error, error} -> fail_preparation(session, error)
      false -> fail_preparation(session, %Error{category: :identity_conflict, operation: :start})
    end
  end

  defp dispatch(session, record) do
    with {:ok, current} <- Session.claim(session) do
      if current.cancel_requested_at_ms != nil or
           Session.remaining(session, record, :preparation) <= 0,
         do: fail_preparation(session, %Error{category: :expired, operation: :runtime}),
         else: verify_dispatch(session, current)
    end
  end

  defp verify_dispatch(session, current) do
    with {:ok, observed} <-
           Session.io(session, current, :preparation, fn ->
             Client.inspect_machine(session.worker.client, current.machine_name)
           end),
         true <-
           Machine.same_incarnation?(current.created_machine, observed) and
             observed.state == :running,
         {:ok, fresh} <- Session.claim(session) do
      dispatch_fresh(session, fresh)
    else
      false ->
        fail_preparation(session, %Error{category: :identity_conflict, operation: :inspect})

      {:error, error} ->
        fail_preparation(session, error)
    end
  end

  defp dispatch_fresh(session, %{cancel_requested_at_ms: nil} = record) do
    with {:ok, intent} <-
           Session.write(session, record, state: :dispatching, evidence: :dispatch_uncertain),
         {:ok, observed} <- Observation.run(session, intent) do
      if observed.state == :collecting,
        do: Files.collect(session, observed),
        else: {:ok, observed}
    end
  end

  defp dispatch_fresh(session, _record),
    do: Session.patch(session, state: :cancelled)

  defp fail_preparation(session, error) do
    with {:ok, record} <- Session.claim(session),
         do: record_preparation_failure(session, record, error)
  end

  defp record_preparation_failure(session, %{state: state} = record, error)
       when state in [:preparing, :ready] do
    outcome = if record.cancel_requested_at_ms, do: :cancelled, else: :failed
    Session.write(session, record, state: outcome, last_error: error)
  end

  defp record_preparation_failure(_session, _record, error), do: {:error, error}
end
