defmodule SmolBox.Embedded.GrowthTransition do
  @moduledoc false
  alias SmolBox.Embedded.{MaterialProof, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{schema: 1, previous: map(), receipt: map(), change: map()}

  @receipt ~w(target_id domain_generation name owner_token incarnation material_sha256)
  @proof ~w(schema revision record_sha256 chain_sha256 operation_id request_sha256)
  @change ~w(operation_id request previous immutable_sha256 previous_storage_gib previous_overlay_gib storage_gib overlay_gib)
  @request ~w(storage_gib overlay_gib)

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

  def valid?(%__MODULE__{} = transition) do
    Validation.struct_shape?(transition, __MODULE__) and transition.schema == 1 and
      Shape.receipt?(transition.previous, 2) and Shape.receipt?(transition.receipt, 2) and
      Map.take(transition.previous, @receipt) == Map.take(transition.receipt, @receipt) and
      change?(transition.change) and proof?(transition)
  end

  def valid?(_transition), do: false

  # This binds the correlated helper result to already persisted intent. Hashes
  # are history checks, not signatures or authority to adopt current inventory.
  def bound?(transition, previous, id, request, previous_sizes, targets) do
    valid?(transition) and transition.previous == previous and
      transition.change["operation_id"] == id and transition.change["request"] == request and
      sizes(transition.change, "previous_") == previous_sizes and
      sizes(transition.change, "") == targets
  end

  def chain(transitions, origin, initial_sizes) do
    if Validation.list?(transitions, 32) and root?(origin) and sizes?(initial_sizes) do
      Enum.reduce_while(transitions, {:ok, origin, initial_sizes, MapSet.new(), nil}, &link/2)
      |> case do
        {:ok, receipt, sizes, _ids, _immutable} -> {:ok, receipt, sizes}
        :error -> :error
      end
    else
      :error
    end
  end

  def root?(receipt) do
    Shape.receipt?(receipt, 2) and receipt["material"]["revision"] == 0 and
      receipt["material"]["chain_sha256"] ==
        digest(["smolbox-material-origin-v2", ordered(receipt, @receipt)])
  end

  defp link(transition, {:ok, previous, old_sizes, ids, immutable}) do
    if valid?(transition) do
      change = transition.change
      id = change["operation_id"]
      next_immutable = change["immutable_sha256"]

      if transition.previous == previous and sizes(change, "previous_") == old_sizes and
           not MapSet.member?(ids, id) and (immutable == nil or immutable == next_immutable),
         do:
           {:cont,
            {:ok, transition.receipt, sizes(change, ""), MapSet.put(ids, id), next_immutable}},
         else: {:halt, :error}
    else
      {:halt, :error}
    end
  end

  defp change?(change) do
    Shape.keys?(change, @change) and Shape.id?(change["operation_id"]) and
      Validation.digest?(change["immutable_sha256"]) and MaterialProof.valid?(change["previous"]) and
      request?(change["request"]) and sizes?(sizes(change, "previous_")) and
      sizes?(sizes(change, "")) and grows?(change)
  end

  defp request?(request),
    do:
      Shape.keys?(request, @request) and
        Enum.all?(
          @request,
          &Shape.optional?(request[&1], fn n -> Validation.integer?(n, 1, 64) end)
        ) and
        Enum.any?(@request, &(request[&1] != nil))

  defp sizes?(sizes),
    do:
      Shape.keys?(sizes, @request) and
        Enum.all?(@request, &Validation.integer?(sizes[&1], 1, 64))

  defp sizes(change, prefix),
    do: Map.new(@request, &{&1, change[prefix <> &1]})

  defp grows?(change) do
    old = sizes(change, "previous_")
    next = sizes(change, "")

    old != next and
      Enum.all?(@request, fn key ->
        next[key] >= old[key] and (change["request"][key] || old[key]) == next[key]
      end)
  end

  defp proof?(transition) do
    old = transition.previous["material"]
    next = transition.receipt["material"]
    change = transition.change

    old == change["previous"] and next["revision"] == old["revision"] + 1 and
      (old["revision"] != 0 or root?(transition.previous)) and
      next["operation_id"] == change["operation_id"] and
      next["request_sha256"] == digest(ordered(change["request"], @request)) and
      next["chain_sha256"] ==
        digest([
          "smolbox-material-transition-v2",
          change_payload(change),
          next["record_sha256"]
        ])
  end

  defp change_payload(change) do
    change
    |> Map.put("request", ordered(change["request"], @request))
    |> Map.put("previous", ordered(change["previous"], @proof))
    |> ordered(@change)
  end

  # Match the existing Rust serde struct order, including null omitted targets.
  defp ordered(value, fields),
    do: %Jason.OrderedObject{values: Enum.map(fields, &{&1, Map.fetch!(value, &1)})}

  defp digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
