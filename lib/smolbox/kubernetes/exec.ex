defmodule SmolBox.Kubernetes.Exec do
  @moduledoc false
  alias SmolBox.{Execution, Validation}
  alias SmolBox.Kubernetes.{Exchange, GuestHelper, Operation, Receipt}

  def run(operation, record, command, options) do
    with :ok <- admissible(record, command, options),
         {:ok, payload} <- GuestHelper.encode(command),
         true <-
           Operation.account(operation, 1, byte_size(payload)) <=
             operation.budget.max_request_bytes do
      operation = %{
        operation
        | deadline: min(operation.deadline, Operation.now() + command.timeout_secs * 1000)
      }

      Exchange.run(operation, record, payload, options)
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
end
