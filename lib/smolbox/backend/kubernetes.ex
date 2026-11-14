defmodule SmolBox.Backend.Kubernetes do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.{KubernetesContext, Reference}
  alias SmolBox.{Error, Execution}
  alias SmolBox.Kubernetes.{Assignment, Config, Exec, Files, Health, Inspection, Operation, Pod}

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

  # Operations require a validated assignment. Exec additionally demands a saved
  # ready receipt and fresh complete node evidence. Unassigned health stays closed.
  @impl true
  def supports_operation?(%KubernetesContext{}, operation),
    do:
      operation in [
        :create,
        :inspect_machine,
        :start,
        :delete,
        :exec,
        :exec_stream,
        :upload,
        :download
      ]

  @impl true
  def supports_operation?(
        %Config{controller_guard: %{owner: owner, enrolled: true}},
        :observe_health
      )
      when is_binary(owner), do: true

  @impl true
  def supports_operation?(_context, _operation), do: false

  @impl true
  def invoke(%KubernetesContext{} = context, operation, arguments, budget) do
    with {:ok, op} <- Operation.new(context.config, budget, operation_name(operation)),
         do: object_operation(context.record, op, operation, arguments)
  end

  def invoke(%Config{} = config, :observe_health, [expected], budget),
    do: Health.observe(config, expected, budget)

  def invoke(_context, operation, _arguments, _budget),
    do: unsupported(operation)

  defp object_operation(record, op, operation, [name, command])
       when operation in [:exec, :exec_stream],
       do: object_operation(record, op, operation, [name, command, []])

  defp object_operation(record, op, operation, [name, command, options])
       when operation in [:exec, :exec_stream] and name == record.machine_name,
       do: Exec.run(op, record, command, options)

  defp object_operation(record, op, :create, [assignment])
       when assignment == record.backend_assignment,
       do: Pod.create_once(op, record)

  defp object_operation(record, op, :upload, [name, path, bytes, digest])
       when name == record.machine_name,
       do: Files.upload(op, record, path, bytes, digest)

  defp object_operation(record, op, :download, [name, path, max])
       when name == record.machine_name,
       do: Files.download(op, record, path, max)

  defp object_operation(record, op, operation, [name]) when name == record.machine_name do
    case operation do
      :inspect_machine -> Inspection.observe(op, record)
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
