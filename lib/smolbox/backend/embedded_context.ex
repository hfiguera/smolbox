defmodule SmolBox.Backend.EmbeddedContext do
  @moduledoc false
  alias SmolBox.Backend.Assignment
  alias SmolBox.Embedded.{Config, Identity, Port}
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
    pinned: false
  ]

  def new(config, server) do
    if Config.validate(config) == :ok and server?(server),
      do: {:ok, %__MODULE__{config: config, server: server}},
      else: error()
  end

  def assign(%__MODULE__{} = context, record) do
    with :ok <- validate(record),
         true <- Assignment.approved?(record.backend_assignment, context.config, record.spec),
         true <- record.worker_id == context.config.id do
      {:ok,
       %{
         context
         | assignment: record.backend_assignment,
           identity: if(record.created_machine, do: record.created_machine.backend_identity),
           profile: record.spec.profile,
           spec: record.spec,
           name: record.machine_name
       }}
    else
      _mismatch -> error()
    end
  end

  def scoped?(%__MODULE__{} = context),
    do:
      Assignment.approved?(context.assignment, context.config, context.spec) and
        context.profile == context.spec.profile and
        context.name == context.assignment.creation["name"] and
        (context.identity == nil or Identity.matches?(context.identity, context.assignment))

  def scoped?(_context), do: false

  def receipt(%__MODULE__{identity: %Identity{} = identity}), do: {:ok, identity.receipt}
  def receipt(_context), do: error()
  def bridge(%__MODULE__{config: %{bridge: :port}}), do: Port
  defp server?(pid) when is_pid(pid), do: node(pid) == node()
  defp server?({:global, {Port, target_node}}), do: target_node == node()
  defp server?(_server), do: false
  defp validate(%Execution{} = record), do: Execution.validate(record)
  defp validate(%ManagedMachine{} = record), do: ManagedMachine.validate(record)
  defp validate(_record), do: :error
  defp error, do: {:error, %Error{category: :identity_conflict, operation: :backend}}
end
