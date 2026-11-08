defmodule SmolBox.Embedded.CaptureTransition do
  @moduledoc false
  alias SmolBox.Embedded.{MaterialProof, MaterialTransition, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @request ~w(max_bytes idle)
  @intent ~w(operation_id request previous immutable_sha256 previous_head source_pid growth_immutable_sha256)
  @artifact ~w(sha256 size_bytes head parent)
  @change ~w(intent artifact growth_immutable_sha256)

  def from_wire(value), do: MaterialTransition.from_wire(value, __MODULE__)

  def request(capture),
    do: %{"max_bytes" => capture.spec.policy.max_bytes, "idle" => capture.spec.idle}

  def request?(request),
    do:
      Shape.keys?(request, @request) and request["idle"] == true and
        Validation.integer?(request["max_bytes"], 1, 68_719_476_736)

  def valid?(transition),
    do:
      MaterialTransition.valid?(transition, __MODULE__) and
        change?(transition.change) and proof?(transition)

  def bound?(transition, previous, id, request),
    do: valid?(transition) and intent_bound?(transition, previous, id, request)

  def intent_bound?(transition, previous, id, request),
    do:
      transition.previous == previous and
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

  defp proof?(transition),
    do:
      MaterialTransition.proof?(
        transition,
        transition.change["intent"],
        @request,
        "smolbox-checkpoint-capture-transition-v1",
        payload(transition.change)
      )

  defp payload(change) do
    change
    |> Map.update!("intent", &MaterialTransition.order_intent(&1, @request, @intent))
    |> Map.update!("artifact", &MaterialTransition.ordered(&1, @artifact))
    |> MaterialTransition.ordered(@change)
  end
end
