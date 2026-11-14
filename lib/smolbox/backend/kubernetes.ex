defmodule SmolBox.Backend.Kubernetes do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.{KubernetesContext, Reference}
  alias SmolBox.{Error, Execution}
  alias SmolBox.Kubernetes.{Assignment, Config, Operation, Pod}

  def reference(config) do
    with :ok <- Config.validate(config),
         do:
           {:ok,
            %Reference{
              adapter: __MODULE__,
              kind: :kubernetes,
              id: config.id,
              context: config,
              budget: config.budget
            }}
  end

  @impl true
  def assign(%KubernetesContext{config: config}, record), do: assign(config, record)

  def assign(config, record) do
    with :ok <- Execution.validate(record),
         true <- Assignment.approved?(record.backend_assignment, config, record),
         do: {:ok, %KubernetesContext{config: config, record: record}},
         else: (_ -> unsupported(:create))
  end

  # Object operations require a validated assigned context. Unassigned health,
  # application IO and cleanup completion remain disabled at this phase gate.
  @impl true
  def supports_operation?(%KubernetesContext{}, operation),
    do: operation in [:create, :inspect_machine, :start, :delete]

  @impl true
  def supports_operation?(_context, _operation), do: false

  @impl true
  def invoke(%KubernetesContext{} = context, operation, arguments, budget) do
    with {:ok, op} <- Operation.new(context.config, budget, operation_name(operation)),
         do: object_operation(context.record, op, operation, arguments)
  end

  def invoke(_context, operation, _arguments, _budget),
    do: unsupported(operation)

  defp object_operation(record, op, :create, [assignment])
       when assignment == record.backend_assignment,
       do: Pod.create_once(op, record)

  defp object_operation(record, op, operation, [name]) when name == record.machine_name do
    case operation do
      :inspect_machine -> Pod.observe(op, record)
      :start -> Pod.await_ready(op, record)
      :delete -> Pod.delete(op, record)
      _ -> unsupported(operation)
    end
  end

  defp object_operation(_, _, operation, _), do: unsupported(operation)
  defp operation_name(:inspect_machine), do: :inspect
  defp operation_name(operation), do: operation

  defp unsupported(operation),
    do:
      {:error,
       %Error{
         category: :unsupported_capability,
         operation: operation,
         evidence: :not_dispatched
       }}
end
