defmodule SmolBox.Runtime.KubernetesCleanup do
  @moduledoc false
  alias SmolBox.{Backend, Error, Execution}
  alias SmolBox.Kubernetes.{CleanupProof, Receipt}
  alias SmolBox.Runtime.{KubernetesIO, KubernetesPreparation, Session}

  def run(session, %{cleanup: :complete} = record), do: release(session, record)

  def run(session, %{backend_create_state: :pending, backend_receipt: nil} = record),
    do: complete(session, record, :not_dispatched, Session.now(session))

  def run(session, record) do
    attempts = min(record.cleanup_attempts + 1, session.config.cleanup_attempts)

    with {:ok, started} <-
           Session.write(session, record, cleanup: :in_progress, cleanup_attempts: attempts) do
      result =
        if record.cleanup_attempts < session.config.cleanup_attempts and
             Session.remaining(session, started, :cleanup) > 0,
           do: dispose(session, started),
           else: prove(session, started)

      case result do
        {:ok, cleaned} -> {:ok, cleaned}
        {:error, error} -> retry(session, error)
      end
    end
  end

  defp dispose(session, record) do
    with {:ok, owned} <- KubernetesPreparation.reconcile(session, record) do
      case ownership(session, owned) do
        {:ok, ready} -> delete_and_prove(session, ready)
        {:error, error} -> delete_unqualified(session, owned, error)
      end
    end
  end

  defp ownership(_session, %{backend_receipt: %Receipt{phase: :ready}} = record),
    do: {:ok, record}

  defp ownership(session, record), do: KubernetesPreparation.ready(session, record, :cleanup)

  defp delete_and_prove(session, record) do
    with {:ok, :api_absent} <- delete(session, record), do: prove(session, record)
  end

  # A known UID is still disposable when readiness/capture fails, but API
  # deletion alone cannot qualify its physical cleanup or release its charge.
  defp delete_unqualified(session, record, original_error) do
    case delete(session, record) do
      {:ok, :api_absent} -> {:error, original_error}
      error -> error
    end
  end

  defp delete(session, record),
    do:
      KubernetesIO.call(session, record, :cleanup, fn reference ->
        Backend.delete(reference, record.machine_name)
      end)

  defp prove(session, %{backend_receipt: %Receipt{phase: :ready}} = record) do
    began = Session.now(session)

    with {:ok, %CleanupProof{} = proof} <-
           KubernetesIO.observe(session, record, fn operation, current ->
             KubernetesIO.node(operation, current, :cleanup)
           end),
         true <-
           CleanupProof.releasable?(proof, record.backend_receipt) and
             proof.observed_at_ms >= began and proof.observed_at_ms <= Session.now(session),
         do: complete(session, record, proof, proof.observed_at_ms),
         else: (
           {:error, %Error{}} = error -> error
           _ -> Session.error(:identity_conflict, :cleanup)
         )
  end

  defp prove(_session, _record), do: Session.error(:identity_conflict, :cleanup)

  defp complete(session, record, proof, at) do
    evidence = if record.state == :unknown, do: :termination_confirmed, else: record.evidence

    Session.patch(session,
      backend_cleanup: proof,
      absence_at_ms: at,
      cleanup: :complete,
      evidence: evidence
    )
    |> released(session)
  end

  defp released({:ok, record}, session), do: release(session, record)
  defp released(error, _session), do: error
  defp release(_session, %{reservation: nil} = record), do: {:ok, record}

  defp release(session, record),
    do:
      Session.store(session.config, :release, [
        Execution.key(record),
        Session.guard(record),
        Session.now(session)
      ])

  defp retry(session, error) do
    with {:ok, record} <- Session.claim(session),
         do: retry_record(session, record, error)
  end

  defp retry_record(_session, %{cleanup: :complete}, error), do: {:error, error}

  defp retry_record(session, record, error) do
    exhausted =
      record.cleanup_attempts >= session.config.cleanup_attempts or
        Session.remaining(session, record, :cleanup) <= 0

    Session.write(session, record,
      cleanup: if(exhausted, do: :failed, else: :in_progress),
      last_error: %{error | operation: :cleanup},
      next_due_at_ms: Session.now(session) + if(exhausted, do: 60_000, else: 1000)
    )
  end
end
