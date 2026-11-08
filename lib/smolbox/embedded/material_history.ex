defmodule SmolBox.Embedded.MaterialHistory do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchPublication,
    BranchReleaseTransition,
    CaptureResolutionTransition,
    CaptureTransition,
    GrowthTransition
  }

  alias SmolBox.Validation

  def chain(transitions, origin, sizes) do
    if sizes?(sizes), do: reduce(transitions, origin, sizes), else: :error
  end

  def identity?(history, receipt, last) do
    if bounded?(history) and history != [] and Enum.any?(history, &requires_history?/1) do
      case reduce(history, hd(history).previous, :unknown) do
        {:ok, ^receipt, _} -> List.last(history) == last
        :error -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp reduce(transitions, origin, sizes) do
    if bounded?(transitions) and GrowthTransition.root?(origin) do
      initial = %{
        receipt: origin,
        sizes: sizes,
        ids: MapSet.new(),
        growth: nil,
        capture: nil,
        head: :unknown,
        lineage: :unknown,
        platform: :unknown,
        sealed: false
      }

      case Enum.reduce_while(transitions, {:ok, initial}, &link/2) do
        {:ok, state} -> {:ok, state.receipt, state.sizes}
        :error -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp link(_, {:ok, %{sealed: true}}), do: {:halt, :error}

  defp link(%GrowthTransition{} = transition, {:ok, state}) do
    change = transition.change
    previous_sizes = Map.new(~w(storage_gib overlay_gib), &{&1, change["previous_" <> &1]})

    if GrowthTransition.valid?(transition) and current?(transition, state, change["operation_id"]) and
         compatible?(state.growth, change["immutable_sha256"]) and
         compatible?(state.sizes, previous_sizes) do
      next = %{
        state
        | sizes: Map.take(change, ~w(storage_gib overlay_gib)),
          growth: change["immutable_sha256"],
          capture: nil
      }

      advance(next, transition, change["operation_id"])
    else
      {:halt, :error}
    end
  end

  defp link(%CaptureTransition{} = transition, {:ok, state}),
    do: capture_link(transition, CaptureTransition.valid?(transition), state)

  defp link(%CaptureResolutionTransition{} = transition, {:ok, state}),
    do: capture_link(transition, CaptureResolutionTransition.valid?(transition), state)

  defp link(%BranchPublication{} = transition, {:ok, state}) do
    change = transition.change
    intent = change["child_origin"]["intent"]
    id = intent["child"]["operation_id"]

    if BranchPublication.valid?(transition) and current?(transition, state, id) and
         compatible?(state.growth, change["previous_growth_sha256"]) and
         compatible?(state.capture, change["previous_capture_sha256"]) and
         head_compatible?(state.head, change["checkpoint_head"]) and
         head_compatible?(state.lineage, change["previous_lineage"]) and
         head_compatible?(state.platform, change["platform"]) and
         backing_sizes?(state.sizes, intent["plan"]["ordinary_child"]["disk_gb"]) do
      next = %{
        state
        | growth: change["growth_sha256"],
          capture: change["capture_sha256"],
          head: change["checkpoint_head"],
          lineage: change["lineage"],
          platform: change["platform"]
      }

      advance(next, transition, id)
    else
      {:halt, :error}
    end
  end

  defp link(%BranchReleaseTransition{} = transition, {:ok, state}) do
    change = transition.change
    id = change["request"]["operation_id"]

    if BranchReleaseTransition.valid?(transition) and MapSet.size(state.ids) == 0 and
         current?(transition, state, id) and
         backing_sizes?(
           state.sizes,
           change["binding"]["intent"]["plan"]["ordinary_child"]["disk_gb"]
         ),
       do: advance(%{state | sealed: true}, transition, id),
       else: {:halt, :error}
  end

  defp link(_, _), do: {:halt, :error}

  defp capture_link(transition, valid, state) do
    change = transition.change
    intent = change["intent"]
    id = intent["operation_id"]

    if valid and current?(transition, state, id) and
         compatible?(state.growth, intent["growth_immutable_sha256"]) and
         compatible?(state.capture, intent["immutable_sha256"]) and
         head_compatible?(state.head, intent["previous_head"]) do
      next = %{
        state
        | growth: change["growth_immutable_sha256"],
          capture: intent["immutable_sha256"],
          head: checkpoint_head(transition)
      }

      advance(next, transition, id)
    else
      {:halt, :error}
    end
  end

  defp checkpoint_head(%CaptureTransition{change: change}), do: change["artifact"]["head"]

  defp checkpoint_head(%CaptureResolutionTransition{change: change}),
    do: change["checkpoint_head"]

  defp current?(transition, state, id),
    do: transition.previous == state.receipt and not MapSet.member?(state.ids, id)

  defp advance(state, transition, id),
    do: {:cont, {:ok, %{state | receipt: transition.receipt, ids: MapSet.put(state.ids, id)}}}

  def capture?(%CaptureTransition{}), do: true
  def capture?(%CaptureResolutionTransition{}), do: true
  def capture?(_), do: false
  def branch?(%BranchPublication{}), do: true
  def branch?(%BranchReleaseTransition{}), do: true
  def branch?(_), do: false
  def requires_history?(transition), do: capture?(transition) or branch?(transition)

  defp bounded?(history),
    do:
      Validation.list?(history, 1024) and
        (Enum.any?(history, &branch?/1) or Validation.list?(history, 288))

  defp backing_sizes?(:unknown, _total), do: true
  defp backing_sizes?(sizes, total), do: sizes["storage_gib"] + sizes["overlay_gib"] == total
  defp compatible?(nil, _), do: true
  defp compatible?(:unknown, _), do: true
  defp compatible?(expected, actual), do: expected == actual
  defp head_compatible?(:unknown, _), do: true
  defp head_compatible?(expected, actual), do: expected == actual

  defp sizes?(sizes),
    do:
      is_map(sizes) and map_size(sizes) == 2 and
        Enum.all?(~w(storage_gib overlay_gib), &Validation.integer?(sizes[&1], 1, 64))
end
