defmodule SmolBox.Kubernetes.Assignment do
  @moduledoc """
  Immutable Kubernetes creation intent stored with an execution reservation.

  It binds the exact execution, nonce, source, profile and Pod specification before
  the single create attempt. This internal persisted type is exposed for store
  adapters; applications should use the public SmolBox execution APIs.
  """
  alias SmolBox.{Error, Execution, Source, Validation}
  alias SmolBox.Kubernetes.{Binding, Config, ExecutionPolicy, PodIntent, Shape}

  @enforce_keys [
    :binding,
    :pod_name,
    :nonce,
    :source,
    :profile,
    :execution_key,
    :spec_fingerprint,
    :pod_intent,
    :intent_digest
  ]
  @derive {Inspect, only: [:binding, :pod_name]}
  defstruct @enforce_keys ++ [version: 1]
  @type t :: %__MODULE__{}

  # Mint immutable creation intent once before reservation. This constructor
  # does not grant execution admission or dispatch an API request.
  @doc false
  def new(
        config,
        %{__struct__: Execution, scope: scope, id: id, fingerprint: fingerprint, spec: spec} =
          record,
        name
      ) do
    with :ok <- Config.validate(config),
         %{artifact: artifact, profile: profile} <- spec,
         true <-
           Map.get(record, :worker_id) == nil and Map.get(record, :backend_assignment) == nil,
         true <- Map.get(record, :managed_machine) == nil,
         true <- artifact in Enum.map(config.sources, &Source.artifact/1),
         true <- profile in config.profiles,
         true <- ExecutionPolicy.supported?(spec) do
      fields = %{
        binding: Config.binding(config),
        pod_name: name,
        nonce: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        source: artifact,
        profile: profile,
        execution_key: {scope, id},
        spec_fingerprint: fingerprint
      }

      fields = Map.put(fields, :pod_intent, unsigned_manifest(fields))

      assignment = struct!(__MODULE__, Map.put(fields, :intent_digest, intent_digest(fields)))
      if valid?(assignment), do: {:ok, assignment}, else: invalid()
    else
      _unsupported -> invalid()
    end
  end

  def new(_config, _record, _name), do: invalid()

  @doc false
  def valid?(%__MODULE__{} = value),
    do:
      Validation.struct_shape?(value, __MODULE__) and value.version == 1 and
        Binding.valid?(value.binding) and creation?(value) and
        value.pod_intent == unsigned_manifest(value) and
        Validation.digest?(value.intent_digest) and
        value.intent_digest == intent_digest(value)

  def valid?(_value), do: false

  @doc false
  def manifest(%__MODULE__{} = value) do
    value.pod_intent
    |> put_in(["metadata", "annotations", "smolbox.io/intent"], value.intent_digest)
  end

  @doc false
  def record_matches?(
        %__MODULE__{} = value,
        %{__struct__: Execution, spec: %{artifact: artifact, profile: profile}} = record
      ),
      do:
        valid?(value) and value.execution_key == {record.scope, record.id} and
          value.spec_fingerprint == record.fingerprint and
          value.binding.target_id == record.worker_id and
          value.pod_name == record.machine_name and value.source == artifact and
          value.profile == profile and Map.get(record, :managed_machine) == nil

  def record_matches?(_assignment, _record), do: false

  @doc false
  def approved?(value, config, record),
    do:
      Config.validate(config) == :ok and record_matches?(value, record) and
        value.binding == Config.binding(config) and value.profile in config.profiles and
        value.source in Enum.map(config.sources, &Source.artifact/1)

  defp unsigned_manifest(value),
    do:
      PodIntent.manifest(
        value.binding,
        value.source,
        value.profile,
        value.pod_name,
        value.nonce,
        value.spec_fingerprint
      )

  defp intent_digest(value),
    do: Shape.digest({:pod_intent, 1, value.binding.generation, value.pod_intent})

  defp creation?(value),
    do:
      Shape.dns_label?(value.pod_name) and Validation.digest?(value.nonce) and
        source?(value.source) and
        Config.profile?(value.profile) and execution_key?(value.execution_key) and
        Validation.digest?(value.spec_fingerprint)

  defp source?(value) do
    case Source.from_artifact(value) do
      {:ok, %{kind: :oci, architecture: "x86_64"}} -> true
      _invalid -> false
    end
  end

  defp execution_key?({scope, id}),
    do: Validation.identifier?(scope) and Validation.identifier?(id)

  defp execution_key?(_key), do: false
  defp invalid, do: {:error, %Error{category: :unsupported_capability, operation: :create}}
end
