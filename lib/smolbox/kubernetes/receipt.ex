defmodule SmolBox.Kubernetes.Receipt do
  @moduledoc false
  alias SmolBox.{Error, Validation}
  alias SmolBox.Kubernetes.{Assignment, Binding, Observation, Shape}

  @enforce_keys [:binding, :pod_name, :pod_uid, :nonce, :intent_digest, :image_reference]
  @derive {Inspect, only: [:pod_name, :phase]}
  defstruct @enforce_keys ++
              [version: 1, phase: :created, container_id: nil, image_id: nil, observation: nil]

  @type t :: %__MODULE__{}

  def created(assignment, pod_uid) do
    if Assignment.valid?(assignment) and Shape.uid?(pod_uid) do
      {:ok,
       %__MODULE__{
         binding: assignment.binding,
         pod_name: assignment.pod_name,
         pod_uid: pod_uid,
         nonce: assignment.nonce,
         intent_digest: assignment.intent_digest,
         image_reference: assignment.source["reference"]
       }}
    else
      invalid()
    end
  end

  def ready(%__MODULE__{} = receipt, container_id, image_id, observation) do
    candidate = %{
      receipt
      | phase: :ready,
        container_id: container_id,
        image_id: image_id,
        observation: observation
    }

    if valid?(receipt) and valid?(candidate) and
         (receipt.phase == :created or
            (same_incarnation?(receipt, candidate) and
               candidate.observation.observed_at_ms >= receipt.observation.observed_at_ms)),
       do: {:ok, candidate},
       else: invalid()
  end

  def ready(_receipt, _container_id, _image_id, _observation), do: invalid()

  def valid?(%__MODULE__{} = value),
    do:
      Validation.struct_shape?(value, __MODULE__) and value.version == 1 and
        Binding.valid?(value.binding) and Shape.dns_label?(value.pod_name) and
        Shape.uid?(value.pod_uid) and Validation.digest?(value.nonce) and
        Validation.digest?(value.intent_digest) and image_reference?(value.image_reference) and
        phase?(value)

  def valid?(_value), do: false

  def matches_assignment?(value, assignment),
    do:
      valid?(value) and Assignment.valid?(assignment) and value.binding == assignment.binding and
        value.pod_name == assignment.pod_name and value.nonce == assignment.nonce and
        value.intent_digest == assignment.intent_digest and
        value.image_reference == assignment.source["reference"]

  def same_creation?(expected, observed),
    do:
      valid?(expected) and valid?(observed) and expected.binding == observed.binding and
        expected.pod_name == observed.pod_name and expected.pod_uid == observed.pod_uid and
        expected.nonce == observed.nonce and expected.intent_digest == observed.intent_digest and
        expected.image_reference == observed.image_reference

  def same_incarnation?(expected, observed),
    do:
      same_creation?(expected, observed) and expected.phase == observed.phase and
        expected.container_id == observed.container_id and expected.image_id == observed.image_id and
        same_observation?(expected.observation, observed.observation)

  defp same_observation?(nil, nil), do: true

  defp same_observation?(%Observation{} = left, %Observation{} = right),
    do:
      %{
        left
        | observed_at_ms: right.observed_at_ms,
          isolated: right.isolated,
          complete_history: right.complete_history
      } == right

  defp same_observation?(_left, _right), do: false

  defp phase?(%{phase: :created, container_id: nil, image_id: nil, observation: nil}), do: true

  defp phase?(%{phase: :ready} = value),
    do:
      container?(value.container_id) and value.image_id == value.image_reference and
        Observation.matches?(value.observation, value.binding, value.pod_uid)

  defp phase?(_value), do: false

  # This is the imageID form observed for the pinned K3s/containerd combination.
  # Other CRI identity forms require a separately qualified resolution rule.
  defp image_reference?(value),
    do:
      Validation.text?(value, 1024) and
        match?(
          {:ok, _},
          SmolBox.Source.oci(id: "receipt", reference: value, architecture: "x86_64")
        )

  defp container?("containerd://" <> digest), do: Validation.digest?(digest)
  defp container?(_value), do: false
  defp invalid, do: {:error, %Error{category: :identity_conflict, operation: :create}}
end
