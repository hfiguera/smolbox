defmodule SmolBox.Embedded.GrowthTransition do
  @moduledoc false
  alias SmolBox.Embedded.{MaterialProof, MaterialTransition, Shape}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{schema: 1, previous: map(), receipt: map(), change: map()}

  @change ~w(operation_id request previous immutable_sha256 previous_storage_gib previous_overlay_gib storage_gib overlay_gib)
  @request ~w(storage_gib overlay_gib)

  def from_wire(value), do: MaterialTransition.from_wire(value, __MODULE__)

  def valid?(transition),
    do:
      MaterialTransition.valid?(transition, __MODULE__) and
        change?(transition.change) and proof?(transition)

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

  defdelegate root?(receipt), to: MaterialTransition

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

  defp proof?(transition),
    do:
      MaterialTransition.proof?(
        transition,
        transition.change,
        @request,
        "smolbox-material-transition-v2",
        payload(transition.change)
      )

  defp payload(change), do: MaterialTransition.order_intent(change, @request, @change)
end
