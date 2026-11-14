defmodule SmolBox.Kubernetes.Guard do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Kubernetes.{Observation, Operation, Pod, Receipt}

  def check(operation, record) do
    with {:ok, %{phase: :ready}} <- Pod.observe(operation, record),
         :ok <- node_proof(operation, record),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> Operation.error(:identity_conflict, operation.name, :not_dispatched)
         )
  end

  defp node_proof(operation, record) do
    {module, context} = operation.config.node_evidence
    receipt = record.backend_receipt

    with {:ok, budget} <- Operation.node_budget(operation),
         {:ok, %Observation{} = observation} <-
           module.capture(receipt.binding, receipt.pod_uid, budget, context),
         true <-
           Observation.dispatchable?(
             observation,
             receipt.binding,
             receipt.pod_uid,
             System.system_time(:millisecond)
           ),
         {:ok, current} <-
           Receipt.ready(receipt, receipt.container_id, receipt.image_id, observation),
         true <- Receipt.same_incarnation?(receipt, current),
         do: :ok,
         else: (
           {:error, %Error{category: :output_limit}} = error -> error
           _ -> Operation.error(:identity_conflict, operation.name, :not_dispatched)
         )
  end
end
