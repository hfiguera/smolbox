defmodule SmolBox.Wire.SSETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.{Error, Wire.SSE}

  @stream ": keepalive\r\n\r\nevent: stdout\r\ndata: café\r\ndata: next\r\n\r\nevent: stderr\ndata:error\n\nevent: exit\ndata: {\"exitCode\":7}\n\n"
  @events [{:stdout, "café\nnext"}, {:stderr, "error"}, {:exit, 7}]

  test "decodes the captured upstream SSE framing including trailing newlines" do
    wire = File.read!("test/fixtures/wire/exec.sse")
    assert {:ok, state, [{:stdout, "café\n"}, {:exit, 0}]} = SSE.feed(%SSE{}, wire)
    assert :ok = SSE.finish(state)
  end

  property "arbitrary byte chunk boundaries preserve complete events" do
    check all(sizes <- list_of(integer(1..23), min_length: 1, max_length: 40)) do
      chunks = chunks(@stream, sizes)

      {state, events} =
        Enum.reduce(chunks, {%SSE{}, []}, fn chunk, {parser, emitted} ->
          assert {:ok, next, events} = SSE.feed(parser, chunk)
          {next, emitted ++ events}
        end)

      assert events == @events
      assert :ok = SSE.finish(state)
    end
  end

  test "every single-byte boundary, including UTF-8 and CRLF, is supported" do
    chunks = for <<byte <- @stream>>, do: <<byte>>

    {state, events} =
      Enum.reduce(chunks, {%SSE{}, []}, fn chunk, {parser, emitted} ->
        assert {:ok, next, events} = SSE.feed(parser, chunk)
        {next, emitted ++ events}
      end)

    assert events == @events
    assert :ok = SSE.finish(state)
  end

  test "EOF without exit, invalid JSON, duplicate exits, and late output fail" do
    assert {:error, %Error{category: :protocol}} = SSE.finish(%SSE{})
    exit = "event: exit\ndata: {\"exitCode\":0}\n\n"

    for stream <- [
          "event: exit\ndata: oops\n\n",
          "event: exit\ndata: {}\n\n",
          exit <> exit,
          exit <> "event: stdout\ndata: late\n\n",
          "event: stdout\ndata: " <> <<255>> <> "\n\n"
        ] do
      assert {:error, %Error{category: :protocol}} = SSE.feed(%SSE{}, stream)
    end

    assert {:ok, state, []} = SSE.feed(%SSE{}, "event: stdout\ndata: unfinished")
    assert {:error, _error} = SSE.finish(state)
  end

  test "unknown events, fields, and keepalives are ignored; errors are redacted" do
    stream =
      "event: future\nid: future-id\nretry: 5\ndata\n\n" <>
        "event: error\ndata: {\"message\":\"private worker detail\"}\n\n"

    assert {:ok, state, [{:error, :remote}]} = SSE.feed(%SSE{}, stream)
    assert {:error, _error} = SSE.finish(state)

    assert {:error, %Error{category: :protocol}} =
             SSE.feed(%SSE{}, "event: error\ndata: oops\n\n")

    assert {:ok, exited, [{:exit, 0}]} =
             SSE.feed(%SSE{}, "event: exit\ndata: {\"exitCode\":0}\n\n")

    assert {:ok, kept, []} = SSE.feed(exited, ": keepalive\n\n")
    assert :ok = SSE.finish(kept)
  end

  test "bounds incomplete frames, complete frames, and incoming chunks" do
    assert {:error, %Error{category: :output_limit}} = SSE.feed(%SSE{max_chunk_bytes: 2}, "abc")
    assert {:error, %Error{category: :output_limit}} = SSE.feed(%SSE{max_frame_bytes: 2}, "abc")
    assert {:error, %Error{category: :output_limit}} = SSE.feed(%SSE{max_frame_bytes: 2}, "abc\n")
  end

  defp chunks("", _sizes), do: []
  defp chunks(binary, []), do: [binary]

  defp chunks(binary, [size | rest]) do
    {chunk, remaining} = :erlang.split_binary(binary, min(size, byte_size(binary)))
    [chunk | chunks(remaining, rest)]
  end
end
