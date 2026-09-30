defmodule SmolBox.Store.CodecVolumes do
  @moduledoc false
  # Recursively strip only empty defaults for older envelopes; new volume state
  # always requires v15. Old envelopes may not smuggle even empty new fields.
  def required?(%SmolBox.Volume{}), do: true
  def required?(%SmolBox.ManagedMachine{spec: %{volumes: refs}}), do: refs != []
  def required?(%SmolBox.Execution{created_machine: %{mounts: mounts}}), do: mounts != []
  def required?(_), do: false

  def strip(term), do: walk(term, :strip)
  def upgrade(term), do: walk(term, :upgrade)

  defp walk(term, operation) when is_map(term) do
    fields = defaults(Map.get(term, :__struct__))

    result = Enum.reduce(fields, term, &field(&2, &1, operation))

    Map.new(Map.to_list(result), fn {key, value} -> {key, walk(value, operation)} end)
  end

  defp walk(term, operation) when is_list(term), do: walk_list(term, operation)

  defp walk(term, operation) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&walk(&1, operation)) |> List.to_tuple()

  defp walk(term, _), do: term

  defp walk_list([], _), do: []

  defp walk_list([head | tail], operation),
    do: [walk(head, operation) | walk_list(tail, operation)]

  defp walk_list(_, _), do: raise(ArgumentError)

  defp field(acc, {key, value}, :strip),
    do: if(Map.fetch!(acc, key) == value, do: Map.delete(acc, key), else: raise(ArgumentError))

  defp field(acc, {key, value}, :upgrade),
    do: if(Map.has_key?(acc, key), do: raise(ArgumentError), else: Map.put(acc, key, value))

  defp defaults(SmolBox.Machine), do: [mounts: []]
  defp defaults(SmolBox.ManagedMachineSpec), do: [volumes: []]
  defp defaults(SmolBox.ManagedMachine), do: [mounts: [], volume_worker_id: nil]
  defp defaults(_), do: []
end
