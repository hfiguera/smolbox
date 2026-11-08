defmodule SmolBox.Embedded.Frame do
  @moduledoc false
  @maximum 1_048_576
  @derive {Inspect, only: [:expected]}
  defstruct header: <<>>, expected: nil, body: <<>>

  def maximum, do: @maximum

  def push(%__MODULE__{} = frame, data) when is_binary(data) and byte_size(data) <= @maximum + 4,
    do: consume(frame, data, [])

  def push(_frame, _data), do: :error

  def complete?(%__MODULE__{header: <<>>, expected: nil, body: <<>>}), do: true
  def complete?(_frame), do: false

  def encode(body) when is_binary(body) and byte_size(body) > 0 and byte_size(body) <= @maximum,
    do: {:ok, <<byte_size(body)::unsigned-big-32, body::binary>>}

  def encode(_body), do: :error

  defp consume(frame, <<>>, frames), do: {:ok, frame, Enum.reverse(frames)}

  defp consume(%{expected: nil} = frame, data, frames) do
    size = min(4 - byte_size(frame.header), byte_size(data))
    <<part::binary-size(^size), rest::binary>> = data
    header = frame.header <> part

    case header do
      <<length::unsigned-big-32>> when length > 0 and length <= @maximum ->
        consume(%__MODULE__{expected: length}, rest, frames)

      <<_length::unsigned-big-32>> ->
        :error

      _partial ->
        {:ok, %{frame | header: header}, Enum.reverse(frames)}
    end
  end

  defp consume(frame, data, frames) do
    size = min(frame.expected - byte_size(frame.body), byte_size(data))
    <<part::binary-size(^size), rest::binary>> = data
    body = <<frame.body::binary, part::binary>>

    if byte_size(body) == frame.expected,
      do: consume(%__MODULE__{}, rest, [body | frames]),
      else: {:ok, %{frame | body: body}, Enum.reverse(frames)}
  end
end
