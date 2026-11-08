defmodule SmolBox.Embedded.CaptureAbortSourceQualification do
  @moduledoc false
  alias SmolBox.Embedded.{
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    GrowthTransition,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [:schema, :cleanup, :intent, :state, :record_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @fields ~w(schema cleanup intent state record_sha256 proof_sha256)
  @cleanup ~w(schema previous operation_id request stage_sha256)
  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256 material)
  @material ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)
  @request ~w(max_bytes idle)
  @intent ~w(operation_id request previous immutable_sha256 previous_head source_pid growth_immutable_sha256)

  def from_wire(value) do
    if Shape.keys?(value, @fields) do
      proof =
        struct!(
          __MODULE__,
          Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
        )

      if valid?(proof), do: {:ok, proof}, else: :error
    else
      :error
    end
  end

  def valid?(%__MODULE__{} = proof) do
    Validation.struct_shape?(proof, __MODULE__) and proof.schema == 1 and
      proof.state in ~w(running stopped) and CaptureTransition.intent?(proof.intent) and
      match?({:ok, _}, CaptureStagingCleanupReceipt.from_wire(proof.cleanup)) and
      intent_matches?(proof) and Validation.digest?(proof.proof_sha256) and
      proof.proof_sha256 == digest(proof)
  end

  def valid?(_), do: false

  defp intent_matches?(proof) do
    proof.cleanup["operation_id"] == proof.intent["operation_id"] and
      proof.cleanup["request"] == proof.intent["request"] and
      proof.cleanup["previous"]["material"] == proof.intent["previous"] and
      proof.record_sha256 == proof.intent["previous"]["record_sha256"] and
      (proof.intent["previous"]["revision"] != 0 or
         GrowthTransition.root?(proof.cleanup["previous"]))
  end

  def bound?(proof, previous, id, request),
    do:
      valid?(proof) and proof.cleanup["previous"] == previous and
        proof.cleanup["operation_id"] == id and proof.cleanup["request"] == request

  defp digest(proof) do
    receipt =
      proof.cleanup["previous"]
      |> Map.update!("material", &ordered(&1, @material))
      |> ordered(@receipt)

    cleanup =
      proof.cleanup
      |> Map.put("previous", receipt)
      |> Map.update!("request", &ordered(&1, @request))
      |> ordered(@cleanup)

    intent =
      proof.intent
      |> Map.update!("previous", &ordered(&1, @material))
      |> Map.update!("request", &ordered(&1, @request))
      |> ordered(@intent)

    ["smolbox-preentry-aborted-source-v1", cleanup, intent, proof.state, proof.record_sha256]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}
end
