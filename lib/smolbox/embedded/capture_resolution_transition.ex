defmodule SmolBox.Embedded.CaptureResolutionTransition do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureTransition, MaterialTransition, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @request ~w(max_bytes idle)
  @intent ~w(operation_id request previous immutable_sha256 previous_head source_pid growth_immutable_sha256)
  @change ~w(intent checkpoint_head growth_immutable_sha256)

  def from_wire(value), do: MaterialTransition.from_wire(value, __MODULE__)

  def valid?(transition),
    do:
      MaterialTransition.valid?(transition, __MODULE__) and
        change?(transition.change) and proof?(transition)

  def bound?(transition, previous, id, request),
    do: valid?(transition) and CaptureTransition.intent_bound?(transition, previous, id, request)

  defp change?(change),
    do:
      Shape.keys?(change, @change) and Validation.digest?(change["growth_immutable_sha256"]) and
        CaptureTransition.intent?(change["intent"]) and
        (change["checkpoint_head"] == nil or Shape.hex?(change["checkpoint_head"], 32)) and
        (change["intent"]["previous_head"] == nil or change["checkpoint_head"] != nil)

  defp proof?(transition),
    do:
      MaterialTransition.proof?(
        transition,
        transition.change["intent"],
        @request,
        "smolbox-quiesced-capture-resolution-v1",
        payload(transition.change)
      )

  defp payload(change) do
    change
    |> Map.update!("intent", &MaterialTransition.order_intent(&1, @request, @intent))
    |> MaterialTransition.ordered(@change)
  end
end
