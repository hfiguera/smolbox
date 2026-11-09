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

  Managed native work pins its operational owner PID and channel epoch before
  durable intent writes, retaining that pin through every asynchronous stage.
  Optional adapter `pin/2` leaves HTTP references unchanged. A stale or unavailable
  native pin cannot resolve a replacement owner or authorize request replay.

  Managed operations bind the reference to a validated assigned record before
  invocation. Embedded adapters use its immutable creation intent and saved
  receipt; HTTP adapters retain their existing client context. A native command
  completion can return `{:error, error, result}` when a real Exit and partial
  byte output were observed but completion was disqualified. Both pieces of
  evidence must be preserved; neither authorizes replay or reservation release.
  """
  alias SmolBox.Backend.{Budget, Reference}
  alias SmolBox.Error

  @callback supports_operation?(context :: term(), operation :: atom()) :: boolean()
  @callback invoke(context :: term(), operation :: atom(), arguments :: list(), Budget.t()) ::
              term()
  @callback assign(context :: term(), record :: term()) :: {:ok, term()} | {:error, Error.t()}
  @callback pin(context :: term(), Budget.t()) :: {:ok, term()} | {:error, Error.t()}
  @optional_callbacks assign: 2, pin: 2

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
    resolve_ready_branch: 3,
    branch_release: 2,
    retire_prepared_branch: 3,
    retire_unbooted_branch: 3,
    inspect_unbooted_branch_disposal: 3,
    dispose_unbooted_branch: 3,
    resolve_unbooted_branch_disposal: 3,
    release_branch_backing: 4,
    resolve_branch_deletion: 2,
    collect_branch_deletion: 2,
    continue_branch_deletion: 2,
    cleanup_branch_deletion: 2,
    observe_health: 2,
    qualify_creation: 2,
    inspect_creation: 1,
    qualify_growth: 2,
    qualify_capture: 2,
    cleanup_capture: 3,
    qualify_export: 1,
    inspect_export: 1,
    cleanup_export: 3
  ]

  @doc false
  def operations, do: @operations

  @doc false
  def require_operation(reference, operation) do
    if Reference.valid?(reference) and Keyword.has_key?(@operations, operation) and
         reference.adapter.supports_operation?(reference.context, operation),
       do: :ok,
       else: error(:unsupported_capability, operation)
  end

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
  def pin(%Reference{} = reference) do
    with true <- Reference.valid?(reference),
         {:ok, context} <- pin_context(reference) do
      %{reference | context: context}
    else
      {:error, %Error{} = error} -> raise error
      _invalid -> raise %Error{category: :validation, operation: :backend}
    end
  end

  defp pin_context(reference) do
    if function_exported?(reference.adapter, :pin, 2),
      do: reference.adapter.pin(reference.context, reference.budget),
      else: {:ok, reference.context}
  end

  @doc false
  def assigned(%Reference{} = reference, record) do
    with true <- Reference.valid?(reference) and record_valid?(record),
         true <- reference.id == record.worker_id,
         {:ok, context} <- assign_context(reference, record) do
      %{reference | context: context}
    else
      _mismatch -> raise %Error{category: :identity_conflict, operation: :backend}
    end
  end

  defp record_valid?(%SmolBox.Execution{} = record), do: SmolBox.Execution.validate(record) == :ok

  defp record_valid?(%SmolBox.ManagedMachine{} = record),
    do: SmolBox.ManagedMachine.validate(record) == :ok

  defp record_valid?(%SmolBox.Volume{} = record), do: SmolBox.Volume.validate(record) == :ok

  defp record_valid?(_record), do: false

  defp assign_context(%{kind: :http, context: context}, %{backend_assignment: nil}),
    do: {:ok, context}

  defp assign_context(%{kind: :http, context: context}, %SmolBox.Volume{native_authority: nil}),
    do: {:ok, context}

  defp assign_context(%{kind: :http}, _record), do: :error

  defp assign_context(reference, record) do
    if function_exported?(reference.adapter, :assign, 2),
      do: reference.adapter.assign(reference.context, record),
      else: :error
  end

  @doc false
  def invoke(reference, operation, arguments) do
    if Reference.valid?(reference) and is_list(arguments) and
         {operation, length(arguments) + 1} in @operations do
      with :ok <- require_operation(reference, operation),
           do: reference.adapter.invoke(reference.context, operation, arguments, reference.budget)
    else
      error(:validation, :backend)
    end
  end

  defp error(category, operation),
    do: {:error, %Error{category: category, operation: operation, evidence: :not_dispatched}}
end
