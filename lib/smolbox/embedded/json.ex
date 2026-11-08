defmodule SmolBox.Embedded.JSON do
  @moduledoc false
  alias SmolBox.Embedded.Frame
  alias SmolBox.Validation

  def decode(body)
      when is_binary(body) and byte_size(body) > 0 and byte_size(body) <= 1_048_576 do
    with :ok <- scan(body, 0, false, false, 0),
         {:ok, value} <- Jason.decode(body, objects: :ordered_objects, strings: :copy),
         {:ok, normalized} <- normalize(value, 0) do
      {:ok, normalized}
    else
      _invalid -> :error
    end
  end

  def decode(_body), do: :error

  def encode(value) do
    with {:ok, normalized} <- normalize(value, 0),
         true <- encoded_size(normalized) <= Frame.maximum(),
         {:ok, body} <- Jason.encode(normalized),
         {:ok, frame} <- Frame.encode(body) do
      {:ok, frame}
    else
      _invalid -> :error
    end
  end

  # Guard parser stack and integer construction before JSON decoding. Escaped
  # quotes and bracket characters in strings do not contribute to depth.
  defp scan(<<>>, 0, false, false, _token), do: :ok
  defp scan(<<>>, _depth, _string, _escape, _token), do: :error
  defp scan(_body, depth, _string, _escape, _token) when depth > 17 or depth < 0, do: :error

  defp scan(<<_byte, rest::binary>>, depth, true, true, _token),
    do: scan(rest, depth, true, false, 0)

  defp scan(<<92, rest::binary>>, depth, true, false, _token),
    do: scan(rest, depth, true, true, 0)

  defp scan(<<34, rest::binary>>, depth, true, false, _token),
    do: scan(rest, depth, false, false, 0)

  defp scan(<<_byte, rest::binary>>, depth, true, false, _token),
    do: scan(rest, depth, true, false, 0)

  defp scan(<<34, rest::binary>>, depth, false, false, _token),
    do: scan(rest, depth, true, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _token) when byte in [123, 91],
    do: scan(rest, depth + 1, false, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _token) when byte in [125, 93],
    do: scan(rest, depth - 1, false, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _token)
       when byte in [9, 10, 13, 32, 44, 58],
       do: scan(rest, depth, false, false, 0)

  defp scan(<<_byte, rest::binary>>, depth, false, false, token) when token < 32,
    do: scan(rest, depth, false, false, token + 1)

  defp scan(_body, _depth, _string, _escape, _token), do: :error

  defp normalize(_value, depth) when depth > 16, do: :error
  defp normalize(%Jason.OrderedObject{values: pairs}, depth), do: object(pairs, depth)
  defp normalize(value, depth) when is_map(value), do: object(Map.to_list(value), depth)

  defp normalize(value, depth) when is_list(value) do
    if Validation.list?(value, 256),
      do: traverse(value, &normalize(&1, depth + 1)),
      else: :error
  end

  defp normalize(value, _depth) when is_binary(value) do
    if Validation.text?(value, 131_072), do: {:ok, value}, else: :error
  end

  defp normalize(value, _depth)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 18_446_744_073_709_551_615,
       do: {:ok, value}

  defp normalize(value, _depth) when value in [true, false, nil], do: {:ok, value}
  defp normalize(_value, _depth), do: :error

  defp object(pairs, depth) do
    with true <- Validation.list?(pairs, 256),
         true <-
           Enum.all?(pairs, fn
             {key, _value} -> Validation.text?(key, 128)
             _invalid -> false
           end),
         true <- MapSet.size(MapSet.new(pairs, &elem(&1, 0))) == length(pairs),
         {:ok, values} <- traverse(pairs, &normalize_pair(&1, depth)) do
      {:ok, Map.new(values)}
    else
      _invalid -> :error
    end
  end

  defp normalize_pair({key, value}, depth) do
    with {:ok, normalized} <- normalize(value, depth + 1), do: {:ok, {key, normalized}}
  end

  defp traverse(values, function) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, accumulator} ->
      case function.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | accumulator]}}
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  # Bound serialization before creating an escaped body. The wire accepts only
  # strings, integer scalars, booleans, null and bounded collections.
  defp encoded_size(value) when is_binary(value), do: 2 + string_size(value, 0)
  defp encoded_size(value) when is_integer(value), do: byte_size(Integer.to_string(value))
  defp encoded_size(true), do: 4
  defp encoded_size(false), do: 5
  defp encoded_size(nil), do: 4

  defp encoded_size(value) when is_list(value),
    do: collection_size(value, &encoded_size/1)

  defp encoded_size(value) when is_map(value),
    do: collection_size(value, fn {key, item} -> encoded_size(key) + 1 + encoded_size(item) end)

  defp collection_size(collection, size) do
    total =
      Enum.reduce_while(collection, 1, fn item, total ->
        next = total + 1 + size.(item)
        if next > Frame.maximum(), do: {:halt, next}, else: {:cont, next}
      end)

    if Enum.empty?(collection), do: 2, else: total
  end

  defp string_size(<<>>, size), do: size

  defp string_size(<<byte, rest::binary>>, size) when byte in [8, 9, 10, 12, 13, 34, 92],
    do: string_size(rest, size + 2)

  defp string_size(<<byte, rest::binary>>, size) when byte < 32,
    do: string_size(rest, size + 6)

  defp string_size(<<_byte, rest::binary>>, size), do: string_size(rest, size + 1)
end
