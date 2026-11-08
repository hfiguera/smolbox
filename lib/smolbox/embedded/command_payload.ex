defmodule SmolBox.Embedded.CommandPayload do
  @moduledoc false
  alias SmolBox.Embedded.Request

  def limits,
    do: %{
      "payload_bytes" => 720_896,
      "chunks" => 11,
      "metadata_bytes" => 8_388_608,
      "stdin_bytes" => 65_536
    }

  def pack(%{"operation" => name, "command" => command} = operation)
      when name in ~w(exec_buffered exec_background exec_stream) do
    if Request.buffered_command_valid?(command) and
         (name == "exec_buffered" or command["stdin"] == nil) do
      env = Enum.sort(command["env"])

      bytes =
        IO.iodata_to_binary([
          "SBCM",
          <<1>>,
          strings(command["argv"]),
          <<length(env)::unsigned-big-16>>,
          Enum.map(env, fn {k, v} -> [string(k), string(v)] end),
          optional(command["workdir"]),
          optional(command["user"]),
          optional(command["stdin"]),
          <<command["max_output_bytes"]::unsigned-big-64>>
        ])

      if byte_size(bytes) <= 720_896,
        do:
          {:ok,
           operation
           |> Map.delete("command")
           |> Map.put("command_payload", %{"schema" => 1, "chunks" => chunks(bytes)})},
        else: :error
    else
      :error
    end
  end

  def pack(operation), do: {:ok, operation}
  defp strings(values), do: [<<length(values)::unsigned-big-16>>, Enum.map(values, &string/1)]
  defp string(value), do: [<<byte_size(value)::unsigned-big-32>>, value]
  defp optional(nil), do: <<0>>
  defp optional(value), do: [<<1>>, string(value)]
  defp chunks(<<>>), do: []
  defp chunks(bytes) when byte_size(bytes) <= 65_536, do: [Base.encode64(bytes)]

  defp chunks(<<head::binary-size(65_536), rest::binary>>),
    do: [Base.encode64(head) | chunks(rest)]
end
