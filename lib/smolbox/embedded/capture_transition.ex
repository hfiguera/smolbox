defmodule SmolBox.Embedded.CaptureTransition do
  @moduledoc false
  alias SmolBox.Embedded.{GrowthTransition, MaterialProof, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256)
  @proof ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)
  @request ~w(max_bytes idle)
  @intent ~w(operation_id request previous immutable_sha256 previous_head source_pid growth_immutable_sha256)
  @artifact ~w(sha256 size_bytes head parent)
  @change ~w(intent artifact growth_immutable_sha256)

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

  def request?(request),
    do:
      Shape.keys?(request, @request) and request["idle"] == true and
        Validation.integer?(request["max_bytes"], 1, 68_719_476_736)

  def valid?(%__MODULE__{} = transition) do
    Validation.struct_shape?(transition, __MODULE__) and transition.schema == 1 and
      Shape.receipt?(transition.previous, 2) and Shape.receipt?(transition.receipt, 2) and
      Map.take(transition.previous, @receipt) == Map.take(transition.receipt, @receipt) and
      change?(transition.change) and proof?(transition)
  end

  def valid?(_), do: false

  def bound?(transition, previous, id, request),
    do:
      valid?(transition) and transition.previous == previous and
        transition.change["intent"]["operation_id"] == id and
        transition.change["intent"]["request"] == request

  defp change?(change) do
    Shape.keys?(change, @change) and Validation.digest?(change["growth_immutable_sha256"]) and
      intent?(change["intent"]) and artifact?(change["artifact"], change["intent"])
  end

  def intent?(intent) do
    Shape.keys?(intent, @intent) and Shape.id?(intent["operation_id"]) and
      request?(intent["request"]) and MaterialProof.valid?(intent["previous"]) and
      Validation.digest?(intent["immutable_sha256"]) and
      Validation.digest?(intent["growth_immutable_sha256"]) and
      (intent["previous_head"] == nil or Shape.hex?(intent["previous_head"], 32)) and
      pid?(intent["source_pid"])
  end

  defp pid?([pid, birth]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(birth, 1, 18_446_744_073_709_551_615)

  defp pid?(_), do: false

  defp artifact?(artifact, intent) do
    Shape.keys?(artifact, @artifact) and Validation.digest?(artifact["sha256"]) and
      Validation.integer?(artifact["size_bytes"], 1, intent["request"]["max_bytes"]) and
      Shape.hex?(artifact["head"], 32) and artifact["parent"] == intent["previous_head"] and
      artifact["parent"] != artifact["head"]
  end

  defp proof?(transition) do
    old = transition.previous["material"]
    next = transition.receipt["material"]
    change = transition.change
    intent = change["intent"]

    old == intent["previous"] and old["revision"] < 1024 and
      next["revision"] == old["revision"] + 1 and
      (old["revision"] != 0 or GrowthTransition.root?(transition.previous)) and
      next["operation_id"] == intent["operation_id"] and
      next["request_sha256"] == digest(ordered(intent["request"], @request)) and
      next["chain_sha256"] ==
        digest([
          "smolbox-checkpoint-capture-transition-v1",
          payload(change),
          next["record_sha256"]
        ])
  end

  defp payload(change) do
    intent =
      change["intent"]
      |> Map.put("request", ordered(change["intent"]["request"], @request))
      |> Map.put("previous", ordered(change["intent"]["previous"], @proof))
      |> ordered(@intent)

    change
    |> Map.put("intent", intent)
    |> Map.put("artifact", ordered(change["artifact"], @artifact))
    |> ordered(@change)
  end

  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}

  defp digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
