defmodule SmolBox.Embedded.PayloadFields do
  @moduledoc false
  def strings(values), do: [<<length(values)::unsigned-big-16>>, Enum.map(values, &string/1)]
  def string(value), do: [<<byte_size(value)::unsigned-big-32>>, value]
  def optional(nil), do: <<0>>
  def optional(value), do: [<<1>>, string(value)]
end
