defmodule SmolBox.Runtime.KubernetesIO do
  @moduledoc false
  alias SmolBox.Backend
  alias SmolBox.Backend.Budget
  alias SmolBox.Kubernetes.Operation
  alias SmolBox.Runtime.{Session, Target}

  def call(session, record, stage, function) do
    Session.io(session, record, stage, fn ->
      reference =
        session.worker
        |> Target.connection(record)
        |> Backend.bounded(timeout_ms: max(1, Session.remaining(session, record, stage)))

      function.(reference)
    end)
  end

  # Post-deadline cleanup may make a fresh, bounded read-only observation. It
  # cannot reset a stage deadline or authorize any further mutation or workload.
  def observe(session, record, function) do
    config = session.worker.kubernetes_config

    with {:ok, budget} <- Budget.constrain(config.budget, timeout_ms: 3000),
         {:ok, operation} <- Operation.new(config, budget, :cleanup) do
      Operation.run(operation, fn _sent -> function.(operation, record) end)
    end
  end

  def node(operation, record, action) do
    {provider, context} = operation.config.node_evidence

    with {:ok, budget} <- Operation.node_budget(operation) do
      case action do
        :capture ->
          provider.capture(
            record.backend_assignment.binding,
            record.backend_receipt.pod_uid,
            budget,
            context
          )

        :cleanup ->
          provider.cleanup(
            record.backend_assignment.binding,
            record.backend_receipt,
            budget,
            context
          )
      end
    end
  end
end
