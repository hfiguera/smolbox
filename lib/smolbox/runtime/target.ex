defmodule SmolBox.Runtime.Target do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Embedded, Features, HTTP, Kubernetes}
  alias SmolBox.Embedded.{CheckpointContract, Config, Port}
  alias SmolBox.{Error, MachineSpec, Source}
  alias SmolBox.Kubernetes.Config, as: KubernetesConfig
  alias SmolBox.Kubernetes.ExecutionPolicy
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
    :registry_credentials,
    :branch_https_credentials
  ]
  @derive {Inspect, only: [:kind, :id, :architecture, :platform, :runtime_version]}
  defstruct [:kind, :id, :connection, :domain_binding, :native_config, :kubernetes_config] ++
              @worker_fields

  @type t :: %__MODULE__{}

  def normalize(%{__struct__: WorkerConfig} = worker) do
    worker
    |> Map.from_struct()
    |> Map.merge(%{kind: :http, id: worker.client.worker.id})
    |> then(&struct!(__MODULE__, &1))
  end

  def normalize(%__MODULE__{} = target), do: target

  def normalize(%KubernetesConfig{} = config) do
    {:ok, reference} = Kubernetes.reference(config)

    fields =
      config
      |> Map.from_struct()
      |> Map.take([
        :architecture,
        :platform,
        :sources,
        :profiles,
        :capacity,
        :allocation_floor,
        :runtime_version,
        :qualification,
        :draining
      ])

    struct!(
      __MODULE__,
      Map.merge(fields, %{
        kind: :kubernetes,
        id: config.id,
        connection: reference,
        domain_binding: KubernetesConfig.binding(config),
        kubernetes_config: config,
        artifacts: [],
        checkpoints: [],
        export_destinations: [],
        checkpoint_policies: [],
        branch_policies: []
      })
    )
  end

  def normalize(%Config{} = config) do
    case Embedded.reference(config, {:global, {Port, node()}}) do
      {:ok, reference} ->
        struct!(
          __MODULE__,
          Map.take(Map.from_struct(config), [
            :architecture,
            :platform,
            :artifacts,
            :profiles,
            :capacity,
            :allocation_floor,
            :qualification,
            :draining,
            :checkpoints,
            :sources,
            :export_destinations,
            :checkpoint_policies,
            :branch_policies,
            :volume_policy,
            :registry_credentials,
            :branch_https_credentials
          ])
          |> Map.merge(%{
            kind: :embedded,
            id: config.id,
            connection: reference,
            domain_binding: Config.domain_binding(config),
            native_config: config,
            runtime_version: config.package_identity["engine_version"]
          })
        )

      {:error, error} ->
        raise error
    end
  end

  # Keep the original HTTP client in normalized targets for existing host tooling.
  # Managed code obtains its adapter reference here, never through worker fields.
  def connection(%{kind: :http, client: client}), do: HTTP.reference(client)
  def connection(%{__struct__: WorkerConfig, client: client}), do: HTTP.reference(client)
  def connection(%KubernetesConfig{} = config), do: normalize(config).connection
  def connection(%__MODULE__{connection: connection}), do: connection

  def connection(target, record), do: target |> connection() |> SmolBox.Backend.assigned(record)

  def require_operation(target, operation),
    do: target |> connection() |> SmolBox.Backend.require_operation(operation)

  # Operational references stay in the task's configuration, never in a record.
  # Preserve an existing pin, including unavailable pins, across every stage.
  def pin(%__MODULE__{kind: :embedded} = target),
    do: %{target | connection: SmolBox.Backend.pin(target.connection)}

  def pin(target), do: target

  def pin_config(config, record, eligible) do
    workers =
      Enum.map(config.workers, fn worker ->
        selected =
          if record.worker_id,
            do: id(worker) == record.worker_id,
            else: id(worker) in eligible and supports?(worker, record.spec)

        if selected, do: pin(worker), else: worker
      end)

    %{config | workers: workers}
  end

  def id(%__MODULE__{id: id}), do: id
  def id(%Config{id: id}), do: id
  def id(%KubernetesConfig{id: id}), do: id
  def id(%{client: %{worker: %{id: id}}}), do: id

  # runtime_version retains the operational health identity (the native engine
  # or HTTP server). SDK/source eligibility must use this distinct identity.
  def sdk_version(%__MODULE__{kind: :embedded, native_config: config}),
    do: Config.sdk_version(config)

  def sdk_version(%Config{} = config), do: Config.sdk_version(config)
  def sdk_version(%KubernetesConfig{}), do: nil
  def sdk_version(%{kind: :kubernetes}), do: nil
  def sdk_version(%{runtime_version: version}), do: version
  def sdk_version(_unrecognized), do: nil

  def supports_feature?(target, feature), do: Features.supports?(target, feature)

  def endpoint(%{kind: :http, client: client}),
    do: {:http, client.worker.base_url, client.worker.unix_socket}

  def endpoint(%{__struct__: WorkerConfig, client: client}),
    do: {:http, client.worker.base_url, client.worker.unix_socket}

  def endpoint(%__MODULE__{kind: kind, domain_binding: domain}), do: {kind, domain}
  def endpoint(%Config{} = config), do: {:embedded, Config.domain_binding(config)}
  def endpoint(%KubernetesConfig{} = config), do: {:kubernetes, KubernetesConfig.binding(config)}

  def validate(%{__struct__: WorkerConfig} = worker), do: WorkerConfig.validate(worker)
  def validate(%Config{} = config), do: Config.validate(config)
  def validate(%KubernetesConfig{} = config), do: KubernetesConfig.validate(config)

  def validate(%__MODULE__{kind: :http} = target) do
    worker = target |> Map.take(@worker_fields) |> then(&struct!(WorkerConfig, &1))

    with true <- SmolBox.Validation.struct_shape?(target, __MODULE__),
         :ok <- WorkerConfig.validate(worker),
         true <- target.id == worker.client.worker.id,
         true <-
           target.connection == nil and target.domain_binding == nil and
             target.native_config == nil and target.kubernetes_config == nil do
      :ok
    else
      _ -> {:error, %SmolBox.Error{category: :validation, operation: :worker}}
    end
  end

  def validate(%__MODULE__{kind: :embedded, native_config: config} = target) do
    with :ok <- Config.validate(config),
         true <- SmolBox.Validation.struct_shape?(target, __MODULE__),
         true <- target == normalize(config),
         do: :ok,
         else: (_invalid -> {:error, %Error{category: :validation, operation: :worker}})
  end

  def validate(%__MODULE__{kind: :kubernetes, kubernetes_config: config} = target) do
    with :ok <- KubernetesConfig.validate(config),
         true <- SmolBox.Validation.struct_shape?(target, __MODULE__),
         true <- target == normalize(config),
         do: :ok,
         else: (_invalid -> {:error, %Error{category: :validation, operation: :worker}})
  end

  def validate(_), do: {:error, %SmolBox.Error{category: :validation, operation: :worker}}

  def supports?(%__MODULE__{kind: :embedded, native_config: config}, spec),
    do: Assignment.supports?(config, spec)

  def supports?(%Config{} = config, spec), do: Assignment.supports?(config, spec)
  def supports?(%KubernetesConfig{} = config, spec), do: kubernetes_approved?(config, spec)

  def supports?(%{kind: :kubernetes, kubernetes_config: config}, spec),
    do: kubernetes_approved?(config, spec)

  def supports?(%{kind: :kubernetes}, _spec), do: false

  def supports?(target, spec), do: WorkerConfig.supports?(worker_definition(target), spec)

  def https_branches?(%__MODULE__{kind: :http} = target, profile),
    do: WorkerConfig.https_branches?(worker_definition(target), profile)

  def https_branches?(%__MODULE__{kind: :embedded, native_config: config}, profile),
    do:
      CheckpointContract.https_approved?(config) and
        SmolBox.BranchHTTPSCredentials.network?(profile.network)

  def https_branches?(_target, _profile), do: false

  defp kubernetes_approved?(%KubernetesConfig{} = config, spec),
    do:
      KubernetesConfig.validate(config) == :ok and ExecutionPolicy.supported?(spec) and
        spec.profile in config.profiles and
        Enum.any?(config.sources, &(SmolBox.Source.artifact(&1) == spec.artifact))

  defp kubernetes_approved?(_config, _spec), do: false

  def allocation_record(
        %__MODULE__{kind: :embedded, native_config: config} = target,
        record,
        name
      ) do
    with {:ok, assignment} <-
           Assignment.new(config, record.spec, name, Map.get(record, :native_mounts, [])),
         do: {:ok, {target.id, name, target.capacity, assignment}}
  end

  def allocation_record(%__MODULE__{kind: :kubernetes} = target, record, name) do
    with {:ok, assignment} <-
           SmolBox.Kubernetes.Assignment.new(target.kubernetes_config, record, name),
         do: {:ok, {target.id, name, target.capacity, assignment}}
  end

  def allocation_record(target, record, name), do: allocation(target, record.spec, name)

  def allocation(%__MODULE__{kind: :embedded, native_config: config} = target, spec, name) do
    with {:ok, assignment} <- Assignment.new(config, spec, name),
         do: {:ok, {target.id, name, target.capacity, assignment}}
  end

  def allocation(%{kind: :kubernetes}, _spec, _name),
    do: {:error, %Error{category: :unsupported_capability, operation: :create}}

  def allocation(target, _spec, name), do: {:ok, {id(target), name, target.capacity}}

  def qualify(%__MODULE__{kind: :embedded} = target, spec),
    do: target |> connection() |> SmolBox.Backend.qualify_creation(spec)

  def qualify(%{kind: :kubernetes}, _spec),
    do: {:error, %Error{category: :unsupported_capability, operation: :create}}

  def qualify(_target, _spec), do: :ok

  def machine_spec(
        %__MODULE__{kind: :embedded, native_config: config},
        %{artifact: %{"kind" => "checkpoint"}} = spec,
        name
      ) do
    if Assignment.supports?(config, spec),
      do:
        SmolBox.Checkpoint.machine(
          Enum.find(config.checkpoints, &(SmolBox.Checkpoint.artifact(&1) == spec.artifact)),
          name
        ),
      else: {:error, %Error{category: :unsupported_capability, operation: :create}}
  end

  def machine_spec(%__MODULE__{kind: :embedded, native_config: config}, spec, name) do
    if Assignment.supports?(config, spec) do
      artifact =
        if spec.artifact["kind"] in ["oci", "registry"],
          do: Enum.find(config.sources, &(Source.artifact(&1) == spec.artifact)),
          else:
            Enum.find(
              config.artifacts,
              &(Map.take(&1, ~w(id sha256 architecture)) == spec.artifact)
            )

      profile = spec.profile

      MachineSpec.new(name, if(is_struct(artifact, Source), do: artifact, else: artifact["path"]),
        cpus: profile.cpus,
        memory_mb: profile.memory_mb,
        storage_gb: profile.storage_gb,
        overlay_gb: profile.overlay_gb,
        network: profile.network,
        ports: Map.get(spec, :ports, []),
        workload: Map.get(spec, :workload)
      )
    else
      {:error, %Error{category: :unsupported_capability, operation: :create}}
    end
  end

  def machine_spec(%{kind: :kubernetes}, _spec, _name),
    do: {:error, %Error{category: :unsupported_capability, operation: :create}}

  def machine_spec(target, spec, name),
    do: WorkerConfig.machine_spec(worker_definition(target), spec, name)

  defp worker_definition(%__MODULE__{kind: :http} = target),
    do: target |> Map.take(@worker_fields) |> then(&struct!(WorkerConfig, &1))

  defp worker_definition(%{__struct__: WorkerConfig} = worker), do: worker
end
