defmodule SmolBox.Runtime.Target do
  @moduledoc false
  alias SmolBox.Backend.HTTP
  alias SmolBox.Runtime.WorkerConfig

  @worker_fields [
    :client,
    :architecture,
    :platform,
    :artifacts,
    :profiles,
    :capacity,
    :allocation_floor,
    :runtime_version,
    :qualification,
    :draining,
    :checkpoints,
    :sources,
    :export_destinations,
    :checkpoint_policies,
    :branch_policies,
    :volume_policy,
    :registry_credentials
  ]
  @derive {Inspect,
           only: [:kind, :id, :architecture, :platform, :runtime_version, :qualification]}
  defstruct [:kind, :id, :connection, :domain_binding] ++ @worker_fields

  @type t :: %__MODULE__{}

  def normalize(%{__struct__: WorkerConfig} = worker) do
    worker
    |> Map.from_struct()
    |> Map.merge(%{kind: :http, id: worker.client.worker.id})
    |> then(&struct!(__MODULE__, &1))
  end

  def normalize(%__MODULE__{} = target), do: target

  # Keep the original HTTP client in normalized targets for existing host tooling.
  # Managed code obtains its adapter reference here, never through worker fields.
  def connection(%{kind: :http, client: client}), do: HTTP.reference(client)
  def connection(%{__struct__: WorkerConfig, client: client}), do: HTTP.reference(client)
  def connection(%__MODULE__{connection: connection}), do: connection

  def id(%__MODULE__{id: id}), do: id
  def id(%{client: %{worker: %{id: id}}}), do: id

  def endpoint(%{kind: :http, client: client}),
    do: {:http, client.worker.base_url, client.worker.unix_socket}

  def endpoint(%{__struct__: WorkerConfig, client: client}),
    do: {:http, client.worker.base_url, client.worker.unix_socket}

  def endpoint(%__MODULE__{kind: kind, domain_binding: domain}), do: {kind, domain}

  def validate(%{__struct__: WorkerConfig} = worker), do: WorkerConfig.validate(worker)

  def validate(%__MODULE__{kind: :http} = target) do
    worker = target |> Map.take(@worker_fields) |> then(&struct!(WorkerConfig, &1))

    with true <- SmolBox.Validation.struct_shape?(target, __MODULE__),
         :ok <- WorkerConfig.validate(worker),
         true <- target.id == worker.client.worker.id,
         true <- target.connection == nil and target.domain_binding == nil do
      :ok
    else
      _ -> {:error, %SmolBox.Error{category: :validation, operation: :worker}}
    end
  end

  def validate(_), do: {:error, %SmolBox.Error{category: :validation, operation: :worker}}

  def supports?(target, spec), do: WorkerConfig.supports?(worker_definition(target), spec)

  def machine_spec(target, spec, name),
    do: WorkerConfig.machine_spec(worker_definition(target), spec, name)

  defp worker_definition(%__MODULE__{kind: :http} = target),
    do: target |> Map.take(@worker_fields) |> then(&struct!(WorkerConfig, &1))

  defp worker_definition(%{__struct__: WorkerConfig} = worker), do: worker
end
