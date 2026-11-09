defmodule SmolBox.Embedded.VolumeAttachment do
  @moduledoc false
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.VolumeContract
  alias SmolBox.{Mount, Validation, Volume, VolumeMount}

  @enforce_keys [:volume_key, :binding, :proof, :target, :readonly]
  @derive {Inspect, only: [:binding, :target, :readonly]}
  defstruct @enforce_keys

  def new(%{__struct__: Volume, state: :ready, native_authority: authority} = volume, reference)
      when authority != nil do
    with :ok <- Volume.validate(volume),
         true <- VolumeMount.valid?(reference) and reference.volume_id == volume.id do
      build(volume, reference)
    else
      _ -> :error
    end
  end

  def new(_, _), do: :error

  defp build(volume, reference) do
    attachment = %__MODULE__{
      volume_key: Volume.key(volume),
      binding: volume.native_authority.binding,
      proof: volume.native_authority.provision,
      target: reference.target,
      readonly: reference.readonly
    }

    if valid?(attachment), do: {:ok, attachment}, else: :error
  end

  def valid?(%__MODULE__{} = attachment),
    do:
      Validation.struct_shape?(attachment, __MODULE__) and key?(attachment.volume_key) and
        Binding.valid?(attachment.binding) and Mount.target?(attachment.target) and
        is_boolean(attachment.readonly) and
        VolumeContract.result?(%{
          "result" => "volume",
          "volume" => %{"status" => "provisioned", "proof" => attachment.proof}
        }) and bound_proof?(attachment)

  def valid?(_), do: false

  def matches?(attachment, %{__struct__: Volume, native_authority: authority} = volume)
      when authority != nil,
      do:
        valid?(attachment) and Volume.validate(volume) == :ok and
          attachment.volume_key == Volume.key(volume) and attachment.binding == authority.binding and
          attachment.proof == authority.provision

  def matches?(_, _), do: false

  def path(attachment),
    do:
      attachment.proof["backing"]["policy"]["root"] <>
        "/" <>
        attachment.proof["backing"]["intent"]["worker_volume_id"]

  def wire(attachment),
    do: %{
      "proof" => attachment.proof,
      "target" => attachment.target,
      "readonly" => attachment.readonly
    }

  defp bound_proof?(attachment),
    do:
      attachment.proof["backing"]["target_id"] == attachment.binding.target_id and
        attachment.proof["backing"]["domain_generation"] == attachment.binding.generation

  defp key?({scope, id}), do: Validation.identifier?(scope) and Validation.identifier?(id)
  defp key?(_), do: false
end
