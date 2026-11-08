defmodule SmolBox.Backend.EmbeddedContext do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Features}
  alias SmolBox.Embedded.{Config, Identity, NativeGrowth, Port, Request, Shape}
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
        growth_scope?(context)

  def scoped?(_context), do: false

  def volume_scoped?(%__MODULE__{volume: %Volume{} = volume} = context),
    do:
      volume_approved?(volume, context.config) and
        Enum.all?(
          ~w(assignment identity profile name spec growth capture export history managed_machine)a,
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
