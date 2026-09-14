defmodule SmolBox.Lab.NetworkDNS do
  @moduledoc false

  @spec question_name(binary(), [binary()]) :: {binary(), binary()}
  def question_name(bytes, labels \\ [])

  def question_name(<<0, rest::binary>>, labels),
    do: {labels |> Enum.reverse() |> Enum.join("."), rest}

  def question_name(<<size, label::binary-size(size), rest::binary>>, labels) when size in 1..63,
    do: question_name(rest, [label | labels])
end
