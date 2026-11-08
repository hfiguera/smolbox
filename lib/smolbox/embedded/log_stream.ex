defmodule SmolBox.Embedded.LogStream do
  @moduledoc false
  defstruct buffer: <<>>, count: 0, bytes: 0, max: 1_048_576
  @line_bytes 131_064
  def limits,
    do: %{
      "lines" => 10_000,
      "line_bytes" => @line_bytes,
      "raw_line_bytes" => 1_048_576,
      "output_bytes" => 8_388_608,
      "memory_bytes" => 6_291_456,
      "poll_ms" => 100
    }

  def new(max), do: %__MODULE__{max: max}
  def complete?(state), do: state.buffer == <<>>

  def feed(state, bytes) when is_binary(bytes) and byte_size(bytes) <= 65_536,
    do: parse(%{state | buffer: state.buffer <> bytes}, [])

  def feed(_state, _bytes), do: :error

  defp parse(%{buffer: <<size::unsigned-big-32, _rest::binary>>}, _lines) when size > @line_bytes,
    do: :error

  defp parse(
         %{buffer: <<size::unsigned-big-32, line::binary-size(size), rest::binary>>} = state,
         lines
       ) do
    if String.valid?(line) and state.count < 10_000 and state.bytes + size + 1 <= state.max,
      do:
        parse(%{state | buffer: rest, count: state.count + 1, bytes: state.bytes + size + 1}, [
          line | lines
        ]),
      else: :error
  end

  defp parse(state, lines), do: {:ok, state, Enum.reverse(lines)}

  def decode(bytes, max) do
    with {:ok, state, lines} <- chunks(bytes, new(max), []),
         true <- complete?(state),
         do: {:ok, lines, state},
         else: (_ -> :error)
  end

  defp chunks(<<>>, state, lines), do: {:ok, state, Enum.reverse(lines)}

  defp chunks(bytes, state, lines) do
    size = min(byte_size(bytes), 65_536)
    <<head::binary-size(^size), rest::binary>> = bytes

    with {:ok, next, decoded} <- feed(state, head),
         do: chunks(rest, next, Enum.reverse(decoded, lines))
  end
end
