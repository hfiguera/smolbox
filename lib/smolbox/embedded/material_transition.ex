defmodule SmolBox.Embedded.MaterialTransition do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @fields ~w(schema previous receipt change)
  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256)
  @material ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)

  def from_wire(value, module) do
    if Shape.keys?(value, @fields) do
      fields = Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
      transition = struct!(module, fields)
      if module.valid?(transition), do: {:ok, transition}, else: :error
    else
      :error
    end
  end

  def valid?(transition, module) do
    is_struct(transition, module) and Validation.struct_shape?(transition, module) and
      transition.schema == 1 and Shape.receipt?(transition.previous, 2) and
      Shape.receipt?(transition.receipt, 2) and
      Map.take(transition.previous, @receipt) == Map.take(transition.receipt, @receipt)
  end

  def root?(receipt) do
    Shape.receipt?(receipt, 2) and receipt["material"]["revision"] == 0 and
      receipt["material"]["chain_sha256"] ==
        digest(["smolbox-material-origin-v2", ordered(receipt, @receipt)])
  end

  def proof?(transition, intent, request_fields, domain, payload) do
    old = transition.previous["material"]
    next = transition.receipt["material"]

    old == intent["previous"] and old["revision"] < 1024 and
      next["revision"] == old["revision"] + 1 and
      (old["revision"] != 0 or root?(transition.previous)) and
      next["operation_id"] == intent["operation_id"] and
      next["request_sha256"] == digest(ordered(intent["request"], request_fields)) and
      next["chain_sha256"] == digest([domain, payload, next["record_sha256"]])
  end

  def order_intent(intent, request_fields, intent_fields) do
    intent
    |> Map.update!("request", &ordered(&1, request_fields))
    |> Map.update!("previous", &ordered(&1, @material))
    |> ordered(intent_fields)
  end

  # The field order matches the Rust serde structs, including null fields.
  def ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}

  defp digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
