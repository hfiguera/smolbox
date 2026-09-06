defmodule SmolBox.Validation do
  @moduledoc false

  @spec text?(term(), pos_integer()) :: boolean()
  def text?(value, limit) do
    is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
      not String.contains?(value, "\0")
  end

  @spec identifier?(term()) :: boolean()
  def identifier?(value) do
    text?(value, 128) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)
  end

  @spec digest?(term()) :: boolean()
  def digest?(value) do
    is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  end

  @spec list?(term(), non_neg_integer()) :: boolean()
  def list?([], _remaining), do: true
  def list?([_head | tail], remaining) when remaining > 0, do: list?(tail, remaining - 1)
  def list?(_value, _remaining), do: false

  @spec keys?(term(), [atom()]) :: boolean()
  def keys?(options, allowed) do
    list?(options, length(allowed)) and Keyword.keyword?(options) and
      Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
      length(options) == MapSet.size(MapSet.new(Keyword.keys(options)))
  end

  @spec integer?(term(), integer(), integer()) :: boolean()
  def integer?(value, min, max), do: is_integer(value) and value >= min and value <= max
end
