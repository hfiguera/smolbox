defmodule SmolBox.Runtime.KubernetesPreparation do
  @moduledoc false
  alias SmolBox.{Backend, Error, Machine}
  alias SmolBox.Kubernetes.{Identity, Operation, Pod, Receipt}
  alias SmolBox.Runtime.{Files, KubernetesIO, Session}

  def prepare(session, record) do
    with {:ok, dispatched} <- Session.write(session, record, backend_create_state: :dispatched),
         {:ok, created} <- create(session, dispatched),
         {:ok, saved} <- ready(session, created, :preparation),
         :ok <- Files.stage(session, saved),
         do: Session.patch(session, state: :ready)
  end

  def reconcile(session, %{backend_receipt: nil} = record) do
    with {:ok, receipt} <-
           KubernetesIO.observe(session, record, fn operation, current ->
             Pod.reconcile(operation, current)
           end),
         do: Session.patch(session, backend_receipt: receipt)
  end

  def reconcile(_session, record), do: {:ok, record}

  def ready(session, record, stage) do
    with {:ok, state} <-
           KubernetesIO.call(session, record, stage, fn reference ->
             Backend.start(reference, record.machine_name)
           end),
         {:ok, capture} <- capture(session, record, stage),
         {:ok, receipt} <-
           Receipt.ready(record.backend_receipt, state.container_id, state.image_id, capture),
         do: Session.patch(session, backend_receipt: receipt, created_machine: machine(receipt))
  end

  defp create(session, record) do
    case KubernetesIO.call(session, record, :preparation, fn reference ->
           Backend.create(reference, record.backend_assignment)
         end) do
      {:ok, receipt} -> Session.patch(session, backend_receipt: receipt)
      {:error, error, receipt} -> save_rejected(session, receipt, error)
      error -> error
    end
  end

  defp save_rejected(session, receipt, error) do
    with {:ok, _record} <- Session.patch(session, backend_receipt: receipt),
         do: {:error, error}
  end

  defp capture(session, record, stage),
    do:
      KubernetesIO.call(session, record, stage, fn reference ->
        capture_node(session.worker.kubernetes_config, reference.budget, record)
      end)

  defp capture_node(config, budget, record) do
    budget = %{budget | timeout_ms: min(30_000, budget.timeout_ms)}

    with {:ok, operation} <- Operation.new(config, budget, :inspect),
         do: Operation.run(operation, fn _sent -> capture_until(operation, record) end)
  end

  # API Ready can precede the guard's first complete observation. Retry only
  # read-only capture, within one original stage/operation/aggregate-byte budget.
  # A lost or replaced incarnation never becomes acceptable merely with time.
  defp capture_until(operation, record) do
    case KubernetesIO.node(operation, record, :capture) do
      {:error, %Error{category: :output_limit}} = error -> error
      {:error, %Error{}} = error -> retry_capture(operation, record, error)
      result -> result
    end
  end

  defp retry_capture(operation, record, error) do
    if Operation.remaining(operation) > 250 do
      Process.sleep(250)
      capture_until(operation, record)
    else
      error
    end
  end

  defp machine(receipt),
    do: %Machine{
      name: receipt.pod_name,
      state: :running,
      created_at: nil,
      cpus: 2,
      memory_mb: 1024,
      storage_gb: 20,
      overlay_gb: 10,
      backend_identity: %Identity{receipt: receipt}
    }
end
