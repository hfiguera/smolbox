defmodule SmolBox.Terminal.Wire do
  @moduledoc false
  import Bitwise
  alias SmolBox.Terminal.Result

  # Bound each wire frame before Mint assembles fragments. Compression is disabled.
  def new(websocket, max), do: %{ws: websocket, buffer: <<>>, message_bytes: 0, max: max}

  def feed(state, bytes) when byte_size(bytes) <= 65_536 do
    parse(%{state | buffer: state.buffer <> bytes}, [], 0)
  end

  def feed(_state, _bytes), do: {:error, :output_limit}

  defp parse(_state, _frames, count) when count > 1024, do: {:error, :output_limit}

  defp parse(state, frames, count) do
    case header(state.buffer) do
      :more ->
        {:ok, state, Enum.reverse(frames)}

      {:ok, size, header_size, fin, opcode} ->
        consume(state, frames, count, {size, header_size, fin, opcode})

      :error ->
        {:error, :protocol}
    end
  end

  defp consume(state, frames, count, {size, header_size, fin, opcode}) do
    total = if opcode < 8, do: state.message_bytes + size, else: state.message_bytes

    cond do
      size > min(state.max, 65_536) or total > state.max ->
        {:error, :output_limit}

      byte_size(state.buffer) < size + header_size ->
        {:ok, state, Enum.reverse(frames)}

      true ->
        decode(
          state,
          frames,
          count,
          size + header_size,
          if(fin and opcode < 8, do: 0, else: total)
        )
    end
  end

  defp decode(state, frames, count, size, total) do
    frame = binary_part(state.buffer, 0, size)
    rest = binary_part(state.buffer, size, byte_size(state.buffer) - size)

    case Mint.WebSocket.decode(state.ws, frame) do
      {:ok, ws, decoded} ->
        next = %{state | ws: ws, buffer: rest, message_bytes: total}
        parse(next, Enum.reverse(decoded, frames), count + 1)

      _invalid ->
        {:error, :protocol}
    end
  end

  defp header(<<a, b, rest::binary>>) when (a &&& 112) == 0 and b < 128 do
    case b do
      126 when byte_size(rest) >= 2 ->
        <<n::16, _::binary>> = rest
        if n >= 126, do: {:ok, n, 4, (a &&& 128) != 0, a &&& 15}, else: :error

      127 when byte_size(rest) >= 8 ->
        <<n::64, _::binary>> = rest

        if n >= 65_536 and n < 9_223_372_036_854_775_808,
          do: {:ok, n, 10, (a &&& 128) != 0, a &&& 15},
          else: :error

      n when n < 126 ->
        {:ok, n, 2, (a &&& 128) != 0, a &&& 15}

      _more ->
        :more
    end
  end

  defp header(bytes) when byte_size(bytes) < 2, do: :more
  defp header(_invalid), do: :error

  def event({:binary, bytes}), do: {:ok, {:output, bytes}}

  def event({:text, bytes}) when byte_size(bytes) <= 128 do
    case Jason.decode(bytes) do
      {:ok, %{"type" => "exit", "code" => code} = value} when map_size(value) == 2 ->
        result = %Result{exit_code: code}
        if Result.valid?(result), do: {:ok, {:exit, result}}, else: {:error, :unknown}

      _invalid ->
        {:error, :protocol}
    end
  end

  def event({:ping, data}), do: {:ok, {:pong, data}}
  def event({:pong, _data}), do: {:ok, :ignore}
  def event({:close, _code, _reason}), do: {:error, :unknown}
  def event(_invalid), do: {:error, :protocol}
end
