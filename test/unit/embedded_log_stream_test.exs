defmodule SmolBox.EmbeddedLogStreamTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.LogStream
  defp frame(line), do: <<byte_size(line)::unsigned-big-32, line::binary>>

  test "fragmented prefix and UTF-8 bytes emit complete empty and NUL-bearing lines" do
    bytes = frame("") <> frame("hé\0line")

    {parser, lines} =
      for <<byte <- bytes>>, reduce: {LogStream.new(128), []} do
        {parser, lines} ->
          assert {:ok, next, emitted} = LogStream.feed(parser, <<byte>>)
          {next, lines ++ emitted}
      end

    assert lines == ["", "hé\0line"]
    assert LogStream.complete?(parser) and parser.count == 2 and parser.bytes == 10
    assert {:ok, ^lines, _} = LogStream.decode(bytes, 128)
  end

  test "hostile lengths UTF-8 incomplete messages and aggregate limits reject" do
    assert :error = LogStream.feed(LogStream.new(128), <<0xFFFFFFFF::32>>)
    assert :error = LogStream.decode(frame(<<255>>), 128)
    assert :error = LogStream.decode(frame("short"), 2)
    assert :error = LogStream.decode(<<0, 0, 0>>, 128)
    assert :error = LogStream.decode(binary_part(frame("short"), 0, 5), 128)
    assert :error = LogStream.decode(String.duplicate(frame(""), 10_001), 20_000)
  end
end
