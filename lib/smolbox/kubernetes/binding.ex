defmodule SmolBox.Kubernetes.Binding do
  @moduledoc """
  Durable enrolled identity for the Kubernetes development preview.

  Its canonical generation binds the cluster, namespace, node/boot, RuntimeClass
  and approved runtime policy. Connection and credential contexts are excluded.
  This is persisted store authority; its shape alone never authorizes adoption.
  """
  alias SmolBox.{Error, Validation}
  alias SmolBox.Kubernetes.{RuntimeIdentity, Shape}

  @identity [
    :target_id,
    :cluster_id,
    :cluster_anchor_uid,
    :namespace,
    :namespace_uid,
    :node_name,
    :node_uid,
    :node_boot_id,
    :runtime_class,
    :runtime_class_uid,
    :runtime_policy_digest,
    :runtime_identity
  ]
  @enforce_keys @identity ++ [:generation]
  @derive {Inspect, only: [:kind, :target_id]}
  defstruct @enforce_keys ++ [kind: :kubernetes, version: 1]
  @type t :: %__MODULE__{}

  @doc false
  def new(options) do
    if Validation.keys?(options, @identity) and
         Enum.all?(@identity, &Keyword.has_key?(options, &1)) do
      fields = Map.new(options)
      binding = struct!(__MODULE__, Map.put(fields, :generation, generation(fields)))
      if valid?(binding), do: {:ok, binding}, else: invalid()
    else
      invalid()
    end
  end

  @doc false
  def valid?(%__MODULE__{} = value),
    do:
      Validation.struct_shape?(value, __MODULE__) and value.kind == :kubernetes and
        value.version == 1 and names?(value) and uids?(value) and runtime?(value)

  def valid?(_value), do: false

  defp names?(value),
    do:
      Validation.identifier?(value.target_id) and Validation.identifier?(value.cluster_id) and
        Shape.dns_label?(value.namespace) and Shape.dns_name?(value.node_name) and
        Shape.boot_id?(value.node_boot_id) and Shape.dns_label?(value.runtime_class)

  defp uids?(value),
    do:
      Enum.all?([:cluster_anchor_uid, :namespace_uid, :node_uid, :runtime_class_uid], fn key ->
        Shape.uid?(Map.fetch!(value, key))
      end)

  defp runtime?(value),
    do:
      RuntimeIdentity.valid?(value.runtime_identity) and
        Validation.digest?(value.runtime_policy_digest) and
        Validation.digest?(value.generation) and value.generation == generation(value)

  defp generation(fields), do: Shape.digest({:binding, 1, Map.take(fields, @identity)})
  defp invalid, do: {:error, %Error{category: :validation, operation: :backend}}
end
