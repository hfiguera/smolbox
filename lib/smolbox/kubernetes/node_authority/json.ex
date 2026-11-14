defmodule SmolBox.Kubernetes.NodeAuthority.JSON do
  @moduledoc false
  alias SmolBox.Validation
  @maximum 65_536

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    with :ok <- scan(bytes, 0, false, false, 0),
         {:ok, value} <- Jason.decode(bytes, objects: :ordered_objects, strings: :copy),
         {:ok, normalized} <- normalize(value, 0) do
      {:ok, normalized}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  def encode(value) do
    with {:ok, normalized} <- normalize(value, 0),
         true <- size(normalized) <= @maximum,
         {:ok, bytes} <- Jason.encode(ordered(normalized)),
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  def digest(value) do
    with {:ok, bytes} <- encode(value),
         do: {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  defp scan(<<>>, 0, false, false, _), do: :ok
  defp scan(<<>>, _, _, _, _), do: :error
  defp scan(_, depth, _, _, _) when depth < 0 or depth > 24, do: :error
  defp scan(<<_, rest::binary>>, depth, true, true, _), do: scan(rest, depth, true, false, 0)
  defp scan(<<92, rest::binary>>, depth, true, false, _), do: scan(rest, depth, true, true, 0)

  defp scan(<<34, rest::binary>>, depth, quoted, false, _),
    do: scan(rest, depth, not quoted, false, 0)

  defp scan(<<_, rest::binary>>, depth, true, false, _), do: scan(rest, depth, true, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _) when byte in [91, 123],
    do: scan(rest, depth + 1, false, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _) when byte in [93, 125],
    do: scan(rest, depth - 1, false, false, 0)

  defp scan(<<byte, rest::binary>>, depth, false, false, _) when byte in [9, 10, 13, 32, 44, 58],
    do: scan(rest, depth, false, false, 0)

  defp scan(<<_, rest::binary>>, depth, false, false, token) when token < 20,
    do: scan(rest, depth, false, false, token + 1)

  defp scan(_, _, _, _, _), do: :error

  defp normalize(_, depth) when depth > 24, do: :error
  defp normalize(%Jason.OrderedObject{values: pairs}, depth), do: object(pairs, depth)

  defp normalize(value, depth) when is_map(value) and not is_struct(value),
    do: object(Map.to_list(value), depth)

  defp normalize(value, depth) when is_list(value) do
    if Validation.list?(value, 4096), do: traverse(value, &normalize(&1, depth + 1)), else: :error
  end

  defp normalize(value, _) when is_binary(value),
    do: if(ascii?(value, @maximum), do: {:ok, value}, else: :error)

  defp normalize(value, _)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: {:ok, value}

  defp normalize(value, _) when value in [nil, true, false], do: {:ok, value}
  defp normalize(_, _), do: :error

  defp object(pairs, depth) do
    with true <- Validation.list?(pairs, 4096),
         true <- Enum.all?(pairs, &key?/1),
         true <- length(pairs) == MapSet.size(MapSet.new(pairs, &elem(&1, 0))),
         {:ok, values} <-
           traverse(pairs, &normalize_pair(&1, depth)),
         do: {:ok, Map.new(values)},
         else: (_ -> :error)
  end

  defp key?({key, _}), do: is_binary(key) and byte_size(key) in 1..128 and ascii?(key, 128)
  defp key?(_), do: false

  defp normalize_pair({key, value}, depth) do
    with {:ok, normalized} <- normalize(value, depth + 1), do: {:ok, {key, normalized}}
  end

  defp ascii?(value, maximum), do: byte_size(value) <= maximum and printable?(value)
  defp printable?(<<>>), do: true
  defp printable?(<<byte, rest::binary>>) when byte in 32..126, do: printable?(rest)
  defp printable?(_), do: false

  defp traverse(values, function) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, accumulator} ->
      case function.(item) do
        {:ok, result} -> {:cont, {:ok, [result | accumulator]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      _ -> :error
    end
  end

  defp ordered(value) when is_map(value),
    do:
      Jason.OrderedObject.new(
        value
        |> Enum.sort()
        |> Enum.map(fn {key, item} -> {key, ordered(item)} end)
      )

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp size(value) when is_map(value),
    do: collection_size(value, fn {key, item} -> size(key) + 1 + size(item) end)

  defp size(value) when is_list(value), do: collection_size(value, &size/1)
  defp size(value) when is_binary(value), do: 2 + escaped_size(value, 0)
  defp size(value) when is_integer(value), do: byte_size(Integer.to_string(value))
  defp size(nil), do: 4
  defp size(true), do: 4
  defp size(false), do: 5

  defp collection_size(values, function) do
    result =
      Enum.reduce_while(values, 1, fn item, total ->
        next = total + 1 + function.(item)
        if next > @maximum, do: {:halt, next}, else: {:cont, next}
      end)

    if Enum.empty?(values), do: 2, else: result
  end

  defp escaped_size(<<>>, count), do: count

  defp escaped_size(<<byte, rest::binary>>, count),
    do: escaped_size(rest, count + if(byte in [34, 92], do: 2, else: 1))
end
