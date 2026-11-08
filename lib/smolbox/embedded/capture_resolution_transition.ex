defmodule SmolBox.Embedded.CaptureResolutionTransition do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureTransition, GrowthTransition, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256)
  @proof ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)
  @request ~w(max_bytes idle)
  @intent ~w(operation_id request previous immutable_sha256 previous_head source_pid growth_immutable_sha256)
  @change ~w(intent checkpoint_head growth_immutable_sha256)

  def from_wire(value) do
    if Shape.keys?(value, ~w(schema previous receipt change)) do
      transition =
        struct!(
          __MODULE__,
          Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
        )

      if valid?(transition), do: {:ok, transition}, else: :error
    else
      :error
    end
  end

  def valid?(%__MODULE__{} = transition),
    do:
      Validation.struct_shape?(transition, __MODULE__) and transition.schema == 1 and
        Shape.receipt?(transition.previous, 2) and Shape.receipt?(transition.receipt, 2) and
        Map.take(transition.previous, @receipt) == Map.take(transition.receipt, @receipt) and
        change?(transition.change) and proof?(transition)

  def valid?(_), do: false

  def bound?(transition, previous, id, request),
    do:
      valid?(transition) and transition.previous == previous and
        transition.change["intent"]["operation_id"] == id and
        transition.change["intent"]["request"] == request

  defp change?(change),
    do:
      Shape.keys?(change, @change) and Validation.digest?(change["growth_immutable_sha256"]) and
        CaptureTransition.intent?(change["intent"]) and
        (change["checkpoint_head"] == nil or Shape.hex?(change["checkpoint_head"], 32)) and
        (change["intent"]["previous_head"] == nil or change["checkpoint_head"] != nil)

  defp proof?(transition) do
    old = transition.previous["material"]
    next = transition.receipt["material"]
    intent = transition.change["intent"]

    old == intent["previous"] and old["revision"] < 1024 and
      next["revision"] == old["revision"] + 1 and
      (old["revision"] != 0 or GrowthTransition.root?(transition.previous)) and
      next["operation_id"] == intent["operation_id"] and
      next["request_sha256"] == digest(ordered(intent["request"], @request)) and
      next["chain_sha256"] ==
        digest([
          "smolbox-quiesced-capture-resolution-v1",
          payload(transition.change),
          next["record_sha256"]
        ])
  end

  defp payload(change) do
    intent =
      change["intent"]
      |> Map.put("request", ordered(change["intent"]["request"], @request))
      |> Map.put("previous", ordered(change["intent"]["previous"], @proof))
      |> ordered(@intent)

    change |> Map.put("intent", intent) |> ordered(@change)
  end

  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}

  defp digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
