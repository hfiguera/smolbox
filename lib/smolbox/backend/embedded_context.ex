defmodule SmolBox.Backend.EmbeddedContext do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Features}

  alias SmolBox.Embedded.{
    BranchCompletion,
    Config,
    Identity,
    MaterialHistory,
    NativeBranchDeletion,
    NativeBranchRetirement,
    NativeGrowth,
    Port,
    Request,
    Shape
  }

  alias SmolBox.{Error, Execution, ManagedMachine, Volume}

  @enforce_keys [:config, :server]
  @derive {Inspect, only: []}
  defstruct [
    :config,
    :server,
    :assignment,
    :identity,
    :profile,
    :name,
    :spec,
    :epoch,
    branch_retirement: nil,
    branch_deletion: nil,
    quiesced: false,
    growth: nil,
    capture: nil,
    export: nil,
    history: nil,
    volume: nil,
    managed_machine: nil,
    pinned: false
  ]

  def new(config, server) do
    if Config.validate(config) == :ok and server?(server),
      do: {:ok, %__MODULE__{config: config, server: server}},
      else: error()
  end

  def assign(%__MODULE__{} = context, %Volume{} = volume) do
    if volume_approved?(volume, context.config),
      do:
        {:ok,
         %{
           context
           | volume: volume,
             assignment: nil,
             identity: nil,
             profile: nil,
             name: nil,
             spec: nil,
             growth: nil,
             capture: nil,
             export: nil,
             history: nil,
             branch_retirement: nil,
             branch_deletion: nil,
             managed_machine: nil
         }},
      else: error()
  end

  def assign(%__MODULE__{} = context, record) do
    with :ok <- validate(record),
         true <-
           Assignment.approved?(
             record.backend_assignment,
             context.config,
             record.spec,
             Map.get(record, :managed_machine)
           ),
         true <- record.worker_id == context.config.id do
      {:ok,
       %{
         context
         | volume: nil,
           assignment: record.backend_assignment,
           identity: current_identity(record),
           growth: NativeGrowth.intent(record),
           capture: capture_intent(record),
           export: export_intent(record),
           history: material_history(record),
           branch_retirement: branch_retirement_intent(record),
           branch_deletion: if(NativeBranchDeletion.resolvable?(record), do: record),
           profile: record.spec.profile,
           spec: record.spec,
           managed_machine: Map.get(record, :managed_machine),
           name: record.machine_name
       }}
    else
      _mismatch -> error()
    end
  end

  defp capture_intent(%ManagedMachine{active_capture: id, captures: captures})
       when not is_nil(id),
       do: captures[id]

  defp capture_intent(_), do: nil

  defp export_intent(%ManagedMachine{active_export: id, exports: exports}) when not is_nil(id),
    do: exports[id]

  defp export_intent(_), do: nil

  def branch_retirement_intent(
        %ManagedMachine{branch: %{native_authority: %{completion: %BranchCompletion{}}}} = record
      ),
      do: if(NativeBranchRetirement.eligible?(record), do: record)

  def branch_retirement_intent(_), do: nil

  def scoped?(%__MODULE__{} = context),
    do:
      context.volume == nil and
        Assignment.approved?(
          context.assignment,
          context.config,
          context.spec,
          context.managed_machine
        ) and
        (context.managed_machine == nil or context.identity != nil) and
        context.profile == context.spec.profile and
        context.name == context.assignment.creation["name"] and
        (context.identity == nil or Identity.matches?(context.identity, context.assignment)) and
        intent_scopes?(context)

  def scoped?(_context), do: false

  defp intent_scopes?(context),
    do: growth_scope?(context) and retirement_scope?(context) and deletion_scope?(context)

  defp deletion_scope?(%{branch_deletion: nil}), do: true
  defp deletion_scope?(context), do: branch_deletion_scope?(context)

  defp retirement_scope?(%{branch_retirement: nil}), do: true
  defp retirement_scope?(context), do: branch_retirement_scope?(context)

  def branch_deletion_scope?(%{branch_deletion: %ManagedMachine{} = child} = context),
    do:
      ManagedMachine.validate(child) == :ok and NativeBranchDeletion.resolvable?(child) and
        branch_scope?(context, child)

  def branch_deletion_scope?(_), do: false

  def branch_retirement_scope?(%{branch_retirement: %ManagedMachine{} = child} = context),
    do:
      ManagedMachine.validate(child) == :ok and branch_retirement_intent(child) == child and
        branch_scope?(context, child)

  def branch_retirement_scope?(_), do: false

  defp branch_scope?(context, child),
    do:
      child.spec == context.spec and child.backend_assignment == context.assignment and
        child.machine_name == context.name and child.spec.profile == context.profile and
        NativeGrowth.current_identity(child) == {:ok, context.identity}

  def volume_scoped?(%__MODULE__{volume: %Volume{} = volume} = context),
    do:
      volume_approved?(volume, context.config) and
        Enum.all?(
          ~w(assignment identity profile name spec growth capture export history managed_machine branch_retirement branch_deletion)a,
          &(Map.fetch!(context, &1) == nil)
        )

  def volume_scoped?(_), do: false

  defp volume_approved?(volume, config),
    do:
      Volume.validate(volume) == :ok and config.platform == :linux and
        Features.supports?(config, :volumes) and volume.worker_id == config.id and
        volume.policy == config.volume_policy and
        match?(
          %{binding: %{target_id: target, generation: generation}}
          when target == config.id and generation == config.domain_generation,
          volume.native_authority
        )

  def receipt(%__MODULE__{identity: %Identity{} = identity}), do: {:ok, identity.receipt}
  def receipt(_context), do: error()

  def resources(%__MODULE__{
        identity: %Identity{material_history: [first | _] = history, receipt: receipt} = identity,
        assignment: assignment
      }) do
    initial = assignment.creation["resources"]

    with true <- Identity.valid?(identity),
         {:ok, ^receipt, sizes} <-
           MaterialHistory.chain(
             history,
             first.previous,
             Map.take(initial, ~w(storage_gib overlay_gib))
           ),
         do: Map.merge(initial, sizes),
         else: (_ -> raise %Error{category: :identity_conflict, operation: :backend})
  end

  def resources(%__MODULE__{identity: %Identity{transition: transition}, assignment: assignment})
      when not is_nil(transition),
      do:
        Map.merge(
          assignment.creation["resources"],
          Map.take(transition.change, ~w(storage_gib overlay_gib))
        )

  def resources(%__MODULE__{assignment: assignment}), do: assignment.creation["resources"]

  defp growth_scope?(%{growth: nil}), do: true

  defp growth_scope?(%{growth: growth, identity: %Identity{} = identity} = context) do
    with true <- Shape.keys?(growth, [:id, :state, :receipt, :request, :previous, :targets]),
         true <- Shape.id?(growth.id) and growth.state in [:pending, :dispatching, :unknown],
         true <- growth.receipt == identity.receipt,
         true <- Request.growth_request?(growth.request, growth.previous),
         actual <- resources(context) do
      growth.previous == Map.take(actual, ~w(storage_gib overlay_gib)) and
        growth.targets ==
          Map.new(growth.previous, fn {key, size} -> {key, growth.request[key] || size} end)
    else
      _ -> false
    end
  end

  defp growth_scope?(_context), do: false

  defp current_identity(record) do
    {:ok, identity} = NativeGrowth.current_identity(record)
    identity
  end

  defp material_history(%ManagedMachine{} = record) do
    case NativeGrowth.transitions(record) do
      {:ok, history} -> history
      _ -> nil
    end
  end

  defp material_history(_record), do: nil

  def bridge(%__MODULE__{config: %{bridge: :port}}), do: Port
  defp server?(pid) when is_pid(pid), do: node(pid) == node()
  defp server?({:global, {Port, target_node}}), do: target_node == node()
  defp server?(_server), do: false
  defp validate(%Execution{} = record), do: Execution.validate(record)
  defp validate(%ManagedMachine{} = record), do: ManagedMachine.validate(record)
  defp validate(_record), do: :error
  defp error, do: {:error, %Error{category: :identity_conflict, operation: :backend}}
end
