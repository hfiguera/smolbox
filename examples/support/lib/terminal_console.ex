defmodule SmolBox.Example.TerminalConsole do
  @moduledoc "A bounded line-input console; it does not change the host terminal's settings."
  alias SmolBox.Terminal

  def run(handle) do
    IO.puts(
      "Terminal connected. :resize COLS ROWS, :interrupt, :eof or :close. Other lines go to the guest."
    )

    owner = self()
    reader = spawn_link(fn -> read_line(owner) end)

    try do
      loop(handle, reader)
    after
      Process.unlink(reader)
      Process.exit(reader, :kill)
      Terminal.close(handle)
    end
  end

  # At most one unread line is in the consumer mailbox. The terminal stream itself
  # is pulled by the owner, never pushed into an unbounded mailbox.
  defp read_line(owner) do
    line = read_chunk(<<>>)
    send(owner, {:terminal_line, self(), line})

    receive do
      :next when is_binary(line) -> read_line(owner)
    end
  end

  defp read_chunk(bytes) when byte_size(bytes) >= 1024, do: bytes

  defp read_chunk(bytes) do
    case IO.binread(:stdio, 1) do
      "\n" -> bytes <> "\n"
      data when is_binary(data) -> read_chunk(bytes <> data)
      :eof when bytes != "" -> bytes
      other -> other
    end
  end

  defp loop(handle, reader) do
    receive do
      {:terminal_line, ^reader, line} ->
        dispatch(handle, line)
        send(reader, :next)
    after
      0 -> :ok
    end

    case Terminal.next(handle, 50) do
      {:ok, {:output, bytes}} ->
        IO.binwrite(bytes)
        loop(handle, reader)

      {:ok, {:closed, outcome}} ->
        outcome

      {:error, %{category: :expired}} ->
        loop(handle, reader)

      error ->
        error
    end
  end

  defp dispatch(handle, :eof), do: Terminal.close(handle)

  defp dispatch(handle, line) when is_binary(line) do
    case String.split(String.trim(line)) do
      [":resize", cols, rows] -> resize(handle, Integer.parse(cols), Integer.parse(rows))
      [":interrupt"] -> Terminal.input(handle, <<3>>)
      [":eof"] -> Terminal.input(handle, <<4>>)
      [":close"] -> Terminal.close(handle)
      _command -> Terminal.input(handle, line)
    end
  end

  defp dispatch(handle, _error), do: Terminal.close(handle)
  defp resize(handle, {cols, ""}, {rows, ""}), do: Terminal.resize(handle, cols, rows)
  defp resize(_handle, _cols, _rows), do: IO.puts("Expected :resize COLS ROWS")
end
