defmodule SmolBox.Backend.Embedded do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedBranch,
    EmbeddedBranchBacking,
    EmbeddedBranchDeletion,
    EmbeddedBranchDeletionAction,
    EmbeddedBranchRetirement,
    EmbeddedCapture,
    EmbeddedCaptureCleanup,
    EmbeddedCaptureObservation,
    EmbeddedCaptureResolution,
    EmbeddedContext,
    EmbeddedExport,
    EmbeddedGrowthObservation,
    EmbeddedObservation,
    EmbeddedOperation,
    EmbeddedPreparation,
    EmbeddedPreparedBranchRetirement,
    EmbeddedReply,
    EmbeddedUnbootedBranchDisposal,
    EmbeddedUnbootedBranchRetirement,
    EmbeddedVolume,
    Features,
    Reference
  }

  alias SmolBox.Embedded.{Call, Health}
  alias SmolBox.Terminal.Connection.Embedded, as: TerminalConnection
  alias SmolBox.Terminal.Server

  @observations ~w(health capacity metrics readiness list machine_measurements)a

  def reference(config, server) do
    with {:ok, context} <- EmbeddedContext.new(config, server),
         do:
           {:ok,
            %Reference{
              adapter: __MODULE__,
              kind: :embedded,
              id: config.id,
              context: context,
              budget: config.budget
            }}
  end

  @impl true
  def assign(context, record), do: EmbeddedContext.assign(context, record)

  @impl true
  def pin(context, budget), do: {:ok, Call.pin(context, budget)}

  @impl true
  def supports_operation?(nil, operation) when operation in @observations, do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in @observations,
      do: Features.supports?(config, :observability)

  def supports_operation?(_context, operation) when operation in @observations, do: false

  def supports_operation?(nil, :terminal_preflight), do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, :terminal_preflight),
    do: Features.supports?(config, :terminal_preflight)

  def supports_operation?(nil, :open_managed_terminal), do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, :open_managed_terminal),
    do: Features.supports?(config, :terminals)

  def supports_operation?(nil, operation) when operation in [:list_images, :pull_image], do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [:list_images, :pull_image],
      do: Features.supports?(config, :images)

  def supports_operation?(nil, :logs), do: true

  def supports_operation?(nil, operation)
      when operation in [
             :retire_prepared_branch,
             :retire_unbooted_branch,
             :inspect_unbooted_branch_disposal,
             :dispose_unbooted_branch,
             :resolve_unbooted_branch_disposal,
             :release_branch_backing,
             :resolve_branch_deletion,
             :collect_branch_deletion,
             :continue_branch_deletion,
             :cleanup_branch_deletion,
             :branch_source,
             :branch_absent,
             :branch_create,
             :branch_release,
             :branch_inspect_child,
             :resolve_ready_branch
           ],
      do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [
             :retire_prepared_branch,
             :retire_unbooted_branch,
             :inspect_unbooted_branch_disposal,
             :dispose_unbooted_branch,
             :resolve_unbooted_branch_disposal,
             :release_branch_backing,
             :resolve_branch_deletion,
             :collect_branch_deletion,
             :continue_branch_deletion,
             :cleanup_branch_deletion,
             :branch_source,
             :branch_absent,
             :branch_create,
             :branch_release,
             :branch_inspect_child,
             :resolve_ready_branch
           ],
      do: Features.supports?(config, :branches)

  def supports_operation?(nil, operation)
      when operation in [:export_machine, :qualify_export, :inspect_export, :cleanup_export],
      do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [:export_machine, :qualify_export, :inspect_export, :cleanup_export],
      do: Features.supports?(config, :exports)

  def supports_operation?(nil, :prepare_artifact), do: true
  def supports_operation?(nil, :create_prepared), do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, :create_prepared),
    do: Features.supports?(config, :remote_sources)

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, :prepare_artifact),
    do: Features.supports?(config, :remote_sources)

  def supports_operation?(nil, :expand_disks), do: true
  def supports_operation?(nil, :qualify_growth), do: true

  def supports_operation?(nil, operation)
      when operation in [
             :start_checkpointable,
             :checkpoint_preflight,
             :capture_checkpoint,
             :qualify_capture,
             :cleanup_capture
           ],
      do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [
             :start_checkpointable,
             :checkpoint_preflight,
             :capture_checkpoint,
             :qualify_capture,
             :cleanup_capture
           ],
      do: Features.supports?(config, :checkpoints)

  def supports_operation?(nil, operation) when operation in [:provision_volume, :delete_volume],
    do: true

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [:provision_volume, :delete_volume],
      do: config.platform == :linux and Features.supports?(config, :volumes)

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, operation)
      when operation in [:expand_disks, :qualify_growth],
      do: Features.supports?(config, :disk_growth)

  def supports_operation?(%{__struct__: EmbeddedContext, config: config}, :logs),
    do: Features.supports?(config, :logs)

  def supports_operation?(_context, operation),
    do:
      operation in [
        :observe_health,
        :create,
        :inspect_machine,
        :start,
        :stop,
        :delete,
        :exec,
        :exec_stream,
        :upload,
        :download,
        :qualify_creation,
        :inspect_creation
      ]

  @impl true
  def invoke(context, :observe_health, [expected], budget) do
    if expected == context.config.package_identity["engine_version"] do
      case Call.health(context, budget) do
        {:ok, %{status: :ready} = health} -> observe_dispatch(context, health, budget)
        _unavailable -> {:unavailable, nil}
      end
    else
      {:incompatible, nil}
    end
  end

  def invoke(context, operation, [], budget)
      when operation in ~w(health capacity metrics readiness list)a,
      do: EmbeddedObservation.run(context, operation, budget)

  def invoke(context, :qualify_creation, [spec], budget) do
    with {:ok, request} <- Assignment.qualification(context.config, spec),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384) do
      case Call.run(context, request, budget) do
        {:ok, %{"result" => "qualified"}, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil} ->
          :ok

        result ->
          qualification_error(EmbeddedReply.decode(context, :qualify_creation, request, result))
      end
    end
  end

  def invoke(context, :prepare_artifact, arguments, budget),
    do: EmbeddedPreparation.run(context, arguments, budget)

  def invoke(context, :collect_branch_deletion, [child], budget),
    do: EmbeddedBranchDeletionAction.run(context, child, :collect, budget)

  def invoke(context, :continue_branch_deletion, [child], budget),
    do: EmbeddedBranchDeletionAction.run(context, child, :continue, budget)

  def invoke(context, :cleanup_branch_deletion, [child], budget),
    do: EmbeddedBranchDeletionAction.run(context, child, :cleanup, budget)

  def invoke(context, :resolve_branch_deletion, [child], budget),
    do: EmbeddedBranchDeletion.run(context, child, budget)

  def invoke(context, operation, [parent, child], budget)
      when operation in [
             :inspect_unbooted_branch_disposal,
             :dispose_unbooted_branch,
             :resolve_unbooted_branch_disposal
           ],
      do: EmbeddedUnbootedBranchDisposal.run(context, operation, parent, child, budget)

  def invoke(context, :retire_unbooted_branch, [parent, child], budget),
    do: EmbeddedUnbootedBranchRetirement.run(context, parent, child, budget)

  def invoke(context, :retire_prepared_branch, [parent, child], budget),
    do: EmbeddedPreparedBranchRetirement.run(context, parent, child, budget)

  def invoke(context, :release_branch_backing, [parent, child, removed], budget),
    do: EmbeddedBranchBacking.run(context, parent, child, removed, budget)

  def invoke(context, :branch_absent, [name], budget),
    do: EmbeddedBranchRetirement.run(context, name, budget)

  def invoke(context, operation, arguments, budget)
      when operation in [
             :branch_create,
             :branch_release,
             :branch_inspect_child,
             :resolve_ready_branch
           ],
      do: EmbeddedBranch.run(context, operation, arguments, budget)

  def invoke(context, :capture_checkpoint, arguments, budget),
    do: EmbeddedCapture.run(context, arguments, budget)

  def invoke(context, :export_machine, [_, _, _] = arguments, budget),
    do: EmbeddedExport.invoke(context, :export_machine, arguments, budget)

  def invoke(_context, :export_machine, _arguments, _budget),
    do: EmbeddedExport.failure(:validation, :not_dispatched)

  def invoke(context, operation, [], budget) when operation in [:qualify_export, :inspect_export],
    do: EmbeddedExport.invoke(context, operation, [], budget)

  def invoke(context, :cleanup_export, [_, true] = arguments, budget),
    do: EmbeddedExport.invoke(context, :cleanup_export, arguments, budget)

  def invoke(_context, :cleanup_export, _arguments, _budget),
    do: EmbeddedExport.failure(:validation, :not_dispatched)

  def invoke(%{volume: volume} = context, :provision_volume, [id, size], budget) do
    with true <- volume != nil and volume.worker_volume_id == id and volume.size_gb == size,
         {:ok, %{"volume" => %{"status" => "provisioned"}}} <-
           EmbeddedVolume.run(context, %{"action" => "provision"}, budget),
         do: {:ok, SmolBox.Volume.path(volume)},
         else: (
           {:error, _} = error -> error
           _ -> volume_error()
         )
  end

  def invoke(%{volume: volume} = context, :delete_volume, [id], budget) do
    with true <- volume != nil and volume.worker_volume_id == id,
         {:ok, %{"volume" => %{"status" => "deleted"}}} <-
           EmbeddedVolume.run(context, %{"action" => "delete"}, budget),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> volume_error()
         )
  end

  def invoke(context, :terminal_preflight, [name, spec], budget),
    do: TerminalConnection.preflight(context, name, spec, budget)

  def invoke(context, :open_managed_terminal, [name, spec, consumer, observer], budget) do
    prepare =
      if Features.supports?(context.config, :terminal_preflight),
        do: &TerminalConnection.preflight/4,
        else: &TerminalConnection.source/4

    with {:ok, source} <- prepare.(context, name, spec, budget),
         do: Server.start_connection(source, name, spec, consumer, observer)
  end

  def invoke(context, :cleanup_capture, [capture, true], budget),
    do: EmbeddedCaptureCleanup.run(context, capture, budget)

  def invoke(_context, :cleanup_capture, _arguments, _budget),
    do:
      {:error,
       %SmolBox.Error{category: :validation, operation: :checkpoint, evidence: :not_dispatched}}

  def invoke(context, :qualify_capture, [true], budget),
    do: EmbeddedCaptureResolution.run(context, context.name, budget)

  def invoke(_context, :qualify_capture, _arguments, _budget),
    do:
      {:error,
       %SmolBox.Error{category: :validation, operation: :checkpoint, evidence: :not_dispatched}}

  def invoke(%{growth: %{state: state}} = context, :inspect_machine, [name], budget)
      when state in [:dispatching, :unknown],
      do: EmbeddedGrowthObservation.run(context, name, budget)

  def invoke(%{capture: %{state: state}} = context, :inspect_machine, [name], budget)
      when state in [:dispatching, :unknown],
      do: EmbeddedCaptureObservation.run(context, name, budget)

  def invoke(context, operation, arguments, budget) do
    with {:ok, request, budget, input, callback} <-
           EmbeddedOperation.build(context, operation, arguments, budget) do
      context
      |> Call.run(request, budget, input, callback)
      |> then(&EmbeddedReply.decode(context, operation, request, &1))
    end
  end

  defp observe_dispatch(context, health, budget) do
    described = Health.describe(context.config, health)

    if Features.supports?(context.config, :observability) do
      context = Call.pin(context, budget)
      deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 1000)

      with {:ok, snapshot} <-
             EmbeddedObservation.run(context, :health, observation_budget(budget, deadline)),
           :ok <-
             EmbeddedObservation.run(context, :readiness, observation_budget(budget, deadline)) do
        {:ready, Map.put(described, :inventory, snapshot)}
      else
        _unavailable -> {:degraded, described}
      end
    else
      {:ready, described}
    end
  end

  defp observation_budget(budget, deadline),
    do: %{budget | timeout_ms: max(1, deadline - System.monotonic_time(:millisecond))}

  defp qualification_error({:error, error}), do: {:error, %{error | evidence: :not_dispatched}}

  defp qualification_error(_),
    do: {:error, %SmolBox.Error{category: :unknown, operation: :qualify_creation}}

  defp volume_error,
    do:
      {:error,
       %SmolBox.Error{category: :identity_conflict, operation: :volume, evidence: :not_dispatched}}
end
