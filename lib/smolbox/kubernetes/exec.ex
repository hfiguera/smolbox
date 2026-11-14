defmodule SmolBox.Kubernetes.Exec do
  @moduledoc false
  alias SmolBox.{Error, Execution, Validation}

  alias SmolBox.Kubernetes.{
    GuestHelper,
    Observation,
    Operation,
    Pod,
    Receipt,
    RemoteCommand,
    WebSocket
  }

  def run(operation, record, command, options) do
    with :ok <- admissible(record, command, options),
         {:ok, payload} <- GuestHelper.encode(command),
         true <-
           Operation.account(operation, 1, byte_size(payload)) <=
             operation.budget.max_request_bytes do
      execute(operation, record, payload, options)
    else
      _ -> Operation.error(:unsupported_capability, operation.name, :not_dispatched)
    end
  end

  defp admissible(record, command, options) do
    if Execution.validate(record) == :ok and record.state in [:dispatching, :running] and
         record.spec.command == command and Receipt.valid?(record.backend_receipt) and
         record.backend_receipt.phase == :ready and options?(options, record),
       do: :ok,
       else: :error
  end

  defp options?(options, record),
    do:
      Validation.keys?(options, [:max_output_bytes, :on_event]) and
        Validation.integer?(
          Keyword.get(options, :max_output_bytes, record.spec.profile.max_output_bytes),
          1,
          record.spec.profile.max_output_bytes
        ) and
        (Keyword.get(options, :on_event) == nil or is_function(options[:on_event], 1))

  defp execute(operation, record, payload, options) do
    capture =
      RemoteCommand.new(
        Keyword.get(options, :max_output_bytes, record.spec.profile.max_output_bytes)
      )

    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {:capture, capture})

    operation = %{
      operation
      | deadline:
          min(operation.deadline, Operation.now() + record.spec.command.timeout_secs * 1000)
    }

    callback = options[:on_event]

    try do
      outcome =
        Operation.run(operation, fn sent ->
          with :ok <- preflight(operation, record),
               :ok <-
                 WebSocket.run(operation, record.backend_receipt, payload, table, callback, sent),
               {:ok, result} <- RemoteCommand.result(WebSocket.snapshot(table)),
               :ok <- preflight(operation, record) do
            if callback, do: callback.({:exit, result.exit_code})
            :ok
          end
        end)

      finish(WebSocket.snapshot(table), outcome, operation.name)
    after
      :ets.delete(table)
    end
  end

  defp preflight(operation, record) do
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

    with {:ok, %Observation{} = observation} <-
           module.capture(receipt.binding, receipt.pod_uid, Operation.budget(operation), context),
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
         else: (_ -> Operation.error(:identity_conflict, operation.name, :not_dispatched))
  end

  defp finish(capture, :ok, name), do: outcome(RemoteCommand.result(capture), name)

  defp finish(capture, {:error, %Error{} = error}, name),
    do: outcome(RemoteCommand.result(capture, error.category), name, error.evidence)

  defp finish(capture, {:error, category}, name) when is_atom(category),
    do: outcome(RemoteCommand.result(capture, category), name)

  defp finish(capture, _, name), do: outcome(RemoteCommand.result(capture, :protocol), name)

  defp outcome(result, name, evidence \\ :dispatch_uncertain)
  defp outcome({:ok, result}, _, _), do: {:ok, result}

  defp outcome({:error, category, result}, name, _),
    do:
      {:error,
       %Error{
         category: category,
         operation: name,
         evidence: :exited,
         exit_code: result.exit_code
       }, result}

  defp outcome({:error, category}, name, evidence), do: Operation.error(category, name, evidence)
end
