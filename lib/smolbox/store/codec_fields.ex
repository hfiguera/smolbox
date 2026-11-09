defmodule SmolBox.Store.CodecFields do
  @moduledoc false

  def any_value?(map, predicate), do: any_entry?(:maps.next(:maps.iterator(map)), predicate)

  defp any_entry?({_, value, iterator}, predicate),
    do: predicate.(value) or any_entry?(:maps.next(iterator), predicate)

  defp any_entry?(:none, _predicate), do: false

  # Legacy envelopes must omit new defaults exactly, even when nil or empty.
  def transform_optional(record, defaults, mode, required?) do
    if required?.(record), do: raise(ArgumentError)
    transform(record, defaults, mode)
  end

  def transform(term, defaults, operation) when is_map(term) do
    fields = Map.get(defaults, Map.get(term, :__struct__), [])
    upgraded = Enum.reduce(fields, term, &field(&2, &1, operation))

    Map.new(Map.to_list(upgraded), fn {key, value} ->
      {key, transform(value, defaults, operation)}
    end)
  end

  def transform(term, defaults, operation) when is_list(term),
    do: transform_list(term, defaults, operation)

  def transform(term, defaults, operation) when is_tuple(term),
    do:
      term |> Tuple.to_list() |> Enum.map(&transform(&1, defaults, operation)) |> List.to_tuple()

  def transform(term, _defaults, _operation), do: term

  defp transform_list([], _defaults, _operation), do: []

  defp transform_list([head | tail], defaults, operation),
    do: [transform(head, defaults, operation) | transform_list(tail, defaults, operation)]

  defp transform_list(_tail, _defaults, _operation), do: raise(ArgumentError)

  defp field(term, {key, default}, :strip),
    do:
      if(Map.fetch!(term, key) == default, do: Map.delete(term, key), else: raise(ArgumentError))

  defp field(term, {key, default}, :upgrade),
    do: if(Map.has_key?(term, key), do: raise(ArgumentError), else: Map.put(term, key, default))
end
