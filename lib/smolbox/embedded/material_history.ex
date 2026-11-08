defmodule SmolBox.Embedded.MaterialHistory do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureResolutionTransition, CaptureTransition, GrowthTransition}
  alias SmolBox.Validation

  def chain(transitions, origin, sizes) do
    if Validation.list?(transitions, 288) and GrowthTransition.root?(origin) and sizes?(sizes) do
      Enum.reduce_while(
        transitions,
        {:ok, origin, sizes, MapSet.new(), nil, nil, :unknown},
        &link/2
      )
      |> case do
        {:ok, receipt, sizes, _ids, _growth, _capture, _head} -> {:ok, receipt, sizes}
        :error -> :error
      end
    else
      :error
    end
  end

  def identity?(history, receipt, last) do
    if Validation.list?(history, 288) and history != [] and
         Enum.any?(history, &capture?/1) do
      first = hd(history)

      sizes =
        case Enum.find(history, &match?(%GrowthTransition{}, &1)) do
          nil -> %{"storage_gib" => 1, "overlay_gib" => 1}
          growth -> Map.new(~w(storage_gib overlay_gib), &{&1, growth.change["previous_" <> &1]})
        end

      case chain(history, first.previous, sizes) do
        {:ok, ^receipt, _} -> List.last(history) == last
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp link(%GrowthTransition{} = transition, {:ok, previous, sizes, ids, growth, _capture, head}) do
    change = transition.change

    if GrowthTransition.valid?(transition) and transition.previous == previous and
         not MapSet.member?(ids, change["operation_id"]) and
         (growth == nil or growth == change["immutable_sha256"]) and
         Map.new(~w(storage_gib overlay_gib), &{&1, change["previous_" <> &1]}) == sizes do
      {:cont,
       {:ok, transition.receipt, Map.take(change, ~w(storage_gib overlay_gib)),
        MapSet.put(ids, change["operation_id"]), change["immutable_sha256"], nil, head}}
    else
      {:halt, :error}
    end
  end

  defp link(%CaptureTransition{} = transition, {:ok, previous, sizes, ids, growth, capture, head}) do
    change = transition.change
    intent = change["intent"]

    if CaptureTransition.valid?(transition) and transition.previous == previous and
         not MapSet.member?(ids, intent["operation_id"]) and
         compatible?(growth, intent["growth_immutable_sha256"]) and
         compatible?(capture, intent["immutable_sha256"]) and
         head_compatible?(head, intent["previous_head"]) do
      {:cont,
       {:ok, transition.receipt, sizes, MapSet.put(ids, intent["operation_id"]),
        change["growth_immutable_sha256"], intent["immutable_sha256"], change["artifact"]["head"]}}
    else
      {:halt, :error}
    end
  end

  defp link(
         %CaptureResolutionTransition{} = transition,
         {:ok, previous, sizes, ids, growth, capture, head}
       ) do
    change = transition.change
    intent = change["intent"]

    if CaptureResolutionTransition.valid?(transition) and transition.previous == previous and
         not MapSet.member?(ids, intent["operation_id"]) and
         compatible?(growth, intent["growth_immutable_sha256"]) and
         compatible?(capture, intent["immutable_sha256"]) and
         head_compatible?(head, intent["previous_head"]) do
      {:cont,
       {:ok, transition.receipt, sizes, MapSet.put(ids, intent["operation_id"]),
        change["growth_immutable_sha256"], intent["immutable_sha256"], change["checkpoint_head"]}}
    else
      {:halt, :error}
    end
  end

  defp link(_, _), do: {:halt, :error}

  def capture?(%CaptureTransition{}), do: true
  def capture?(%CaptureResolutionTransition{}), do: true
  def capture?(_), do: false
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
