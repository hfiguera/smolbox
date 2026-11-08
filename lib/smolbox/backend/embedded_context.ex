defmodule SmolBox.Backend.EmbeddedContext do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Embedded.{Config, Identity, NativeGrowth, Port, Request, Shape}
  alias SmolBox.{Error, Execution, ManagedMachine}

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
    managed_machine: nil,
    pinned: false
  ]

  def new(config, server) do
    if Config.validate(config) == :ok and server?(server),
      do: {:ok, %__MODULE__{config: config, server: server}},
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
         | assignment: record.backend_assignment,
           identity: current_identity(record),
           growth: NativeGrowth.intent(record),
           profile: record.spec.profile,
           spec: record.spec,
           managed_machine: Map.get(record, :managed_machine),
           name: record.machine_name
       }}
    else
      _mismatch -> error()
    end
  end

  def scoped?(%__MODULE__{} = context),
    do:
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

  def bridge(%__MODULE__{config: %{bridge: :port}}), do: Port
  defp server?(pid) when is_pid(pid), do: node(pid) == node()
  defp server?({:global, {Port, target_node}}), do: target_node == node()
  defp server?(_server), do: false
  defp validate(%Execution{} = record), do: Execution.validate(record)
  defp validate(%ManagedMachine{} = record), do: ManagedMachine.validate(record)
  defp validate(_record), do: :error
  defp error, do: {:error, %Error{category: :identity_conflict, operation: :backend}}
end
