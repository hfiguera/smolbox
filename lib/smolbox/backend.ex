defmodule SmolBox.Backend do
  @moduledoc """
  Domain-operation boundary for managed runtime backends.

  Managed orchestration supplies a logical target reference and a bounded operation
  budget. Adapters implement lifecycle, observation, command and guest-file operations
  without exposing their transport to the coordinator. The HTTP adapter retains the
  public `SmolBox.Client` and transport extension contracts.

  Unsupported operations fail before invocation with `:not_dispatched` evidence.
  A backend must preserve actual dispatch, exit, and ownership evidence; successful
  transport completion alone never proves command completion or guest termination.
  References and budgets are runtime values, never persisted handles or lease fences.
  """
  alias SmolBox.Backend.{Budget, Reference}
  alias SmolBox.Error

  @callback supports_operation?(context :: term(), operation :: atom()) :: boolean()
  @callback invoke(context :: term(), operation :: atom(), arguments :: list(), Budget.t()) ::
              term()

  @operations [
    health: 1,
    capacity: 1,
    metrics: 1,
    readiness: 1,
    list: 1,
    create: 2,
    create: 3,
    create_prepared: 3,
    create_prepared: 4,
    prepare_artifact: 2,
    prepare_artifact: 3,
    list_images: 2,
    pull_image: 3,
    inspect_machine: 2,
    machine_measurements: 2,
    expand_disks: 3,
    start: 2,
    start_checkpointable: 2,
    checkpoint_preflight: 2,
    capture_checkpoint: 4,
    stop: 2,
    delete: 2,
    exec: 3,
    exec: 4,
    exec_stream: 3,
    exec_stream: 4,
    upload: 5,
    download: 4,
    export_machine: 4,
    provision_volume: 3,
    delete_volume: 2,
    logs: 2,
    logs: 3,
    terminal_preflight: 3,
    open_managed_terminal: 5,
    branch_source: 2,
    branch_absent: 2,
    branch_create: 3,
    branch_inspect_child: 3,
    branch_release: 2,
    observe_health: 2
  ]

  @doc false
  def operations, do: @operations

  for {operation, arity} <- @operations do
    arguments = for index <- 1..(arity - 1)//1, do: Macro.var(:"argument_#{index}", nil)

    @doc false
    def unquote(operation)(reference, unquote_splicing(arguments)),
      do: invoke(reference, unquote(operation), [unquote_splicing(arguments)])
  end

  @doc false
  def bounded(%Reference{} = reference, options) do
    case Budget.constrain(reference.budget, options) do
      {:ok, budget} -> %{reference | budget: budget}
      {:error, error} -> raise error
    end
  end

  @doc false
  def invoke(reference, operation, arguments) do
    if Reference.valid?(reference) and is_list(arguments) and
         {operation, length(arguments) + 1} in @operations do
      if reference.adapter.supports_operation?(reference.context, operation),
        do: reference.adapter.invoke(reference.context, operation, arguments, reference.budget),
        else: error(:unsupported_capability, operation)
    else
      error(:validation, :backend)
    end
  end

  defp error(category, operation),
    do: {:error, %Error{category: category, operation: operation, evidence: :not_dispatched}}
end
