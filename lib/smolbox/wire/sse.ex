defmodule SmolBox.Wire.SSE do
  @moduledoc """
  Incremental parser for the pinned SmolVM exec SSE protocol.

  stdout/stderr are plain lossy UTF-8 data; only exit/error payloads are JSON.
  Unknown additive events and keepalives are ignored. An exit is required for
  successful completion. Terminal duplicates and output after exit are errors.
  Frames and incoming chunks have explicit byte limits; no mailbox is involved.
  """

  alias SmolBox.Error

  defstruct buffer: "",
            event: "message",
            data: [],
            frame_bytes: 0,
            terminal: nil,
            max_frame_bytes: 131_072,
            max_chunk_bytes: 262_144

  @type event ::
          {:stdout, String.t()} | {:stderr, String.t()} | {:exit, integer()} | {:error, :remote}
  @type t :: %__MODULE__{
          buffer: binary(),
          event: binary(),
          data: [binary()],
          frame_bytes: non_neg_integer(),
          terminal: :exit | :error | nil,
          max_frame_bytes: pos_integer(),
          max_chunk_bytes: pos_integer()
        }

  @doc "Consume a bounded chunk; incomplete UTF-8 is retained until the frame is complete."
  @spec feed(t(), binary()) :: {:ok, t(), [event()]} | {:error, Error.t()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    if byte_size(chunk) <= state.max_chunk_bytes do
      parse_lines(%{state | buffer: state.buffer <> chunk}, [])
    else
      limit()
    end
  end

  @doc "EOF is successful only after a complete exit event with no unfinished frame."
  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{buffer: "", data: [], frame_bytes: 0, terminal: :exit}), do: :ok
  def finish(%__MODULE__{}), do: invalid()

  defp parse_lines(state, events) do
    case :binary.match(state.buffer, "\n") do
      :nomatch -> incomplete(state, events)
      {index, 1} -> consume_line(state, index, events)
    end
  end

  defp incomplete(state, events) do
    if state.frame_bytes + byte_size(state.buffer) <= state.max_frame_bytes do
      {:ok, state, Enum.reverse(events)}
    else
      limit()
    end
  end

  defp consume_line(state, index, events) do
    {line, <<"\n", rest::binary>>} = :erlang.split_binary(state.buffer, index)
    bytes = state.frame_bytes + index + 1

    if bytes <= state.max_frame_bytes do
      updated = %{state | buffer: rest, frame_bytes: bytes}

      with {:ok, next, emitted} <- line(updated, trim_cr(line)) do
        parse_lines(next, Enum.reverse(emitted, events))
      end
    else
      limit()
    end
  end

  defp line(state, "") do
    with {:ok, terminal, events} <- dispatch(state) do
      {:ok, %{state | event: "message", data: [], frame_bytes: 0, terminal: terminal}, events}
    end
  end

  defp line(state, <<":", _comment::binary>>), do: {:ok, state, []}

  defp line(state, line) do
    case :binary.split(line, ":") do
      [field, value] -> field(state, field, trim_space(value))
      [field] -> field(state, field, "")
    end
  end

  defp field(state, "event", value), do: {:ok, %{state | event: value}, []}
  defp field(state, "data", value), do: {:ok, %{state | data: [value | state.data]}, []}
  defp field(state, _field, _value), do: {:ok, state, []}

  defp dispatch(%{data: [], terminal: terminal}), do: {:ok, terminal, []}

  defp dispatch(%{event: event, terminal: terminal})
       when event not in ["stdout", "stderr", "exit", "error"], do: {:ok, terminal, []}

  defp dispatch(%{terminal: terminal}) when not is_nil(terminal), do: invalid()

  defp dispatch(state) do
    payload = state.data |> Enum.reverse() |> Enum.join("\n")
    decode_event(state.event, payload)
  end

  defp decode_event("stdout", payload), do: text_event(:stdout, payload)
  defp decode_event("stderr", payload), do: text_event(:stderr, payload)

  defp decode_event("exit", payload) do
    case Jason.decode(payload) do
      {:ok, %{"exitCode" => code}}
      when is_integer(code) and code >= -2_147_483_648 and code <= 2_147_483_647 ->
        {:ok, :exit, [{:exit, code}]}

      _other ->
        invalid()
    end
  end

  defp decode_event("error", payload) do
    case Jason.decode(payload) do
      {:ok, %{"message" => message}} when is_binary(message) -> {:ok, :error, [{:error, :remote}]}
      _other -> invalid()
    end
  end

  defp text_event(event, payload) do
    if String.valid?(payload), do: {:ok, nil, [{event, payload}]}, else: invalid()
  end

  defp trim_space(<<" ", rest::binary>>), do: rest
  defp trim_space(value), do: value

  defp trim_cr(<<>>), do: ""

  defp trim_cr(line) do
    if :binary.last(line) == 13, do: binary_part(line, 0, byte_size(line) - 1), else: line
  end

  defp invalid,
    do:
      {:error,
       %Error{category: :protocol, operation: :exec_stream, evidence: :dispatch_uncertain}}

  defp limit,
    do:
      {:error,
       %Error{category: :output_limit, operation: :exec_stream, evidence: :dispatch_uncertain}}
end
