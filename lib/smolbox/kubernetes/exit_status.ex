defmodule SmolBox.Kubernetes.ExitStatus do
  @moduledoc false

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..8192 do
    with {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         true <- unique?(ordered, 0),
         {:ok, object} when is_map(object) <- Jason.decode(bytes),
         true <- object["kind"] in [nil, "Status"] and object["apiVersion"] in [nil, "v1"],
         do: status(object),
         else: (_ -> :error)
  end

  def decode(_), do: :error

  defp unique?(_, depth) when depth > 16, do: false

  defp unique?(%Jason.OrderedObject{values: pairs}, depth),
    do:
      length(pairs) == MapSet.size(MapSet.new(pairs, &elem(&1, 0))) and
        Enum.all?(pairs, &unique?(elem(&1, 1), depth + 1))

  defp unique?(values, depth) when is_list(values),
    do: Enum.all?(values, &unique?(&1, depth + 1))

  defp unique?(_, _), do: true

  defp status(%{"status" => "Success"} = object) do
    if object["reason"] in [nil, "", "Success"] and object["code"] in [nil, 0, 200] and
         object["details"] in [nil, %{}], do: {:ok, 0}, else: :error
  end

  defp status(%{
         "status" => "Failure",
         "reason" => "NonZeroExitCode",
         "details" => %{"causes" => [%{"reason" => "ExitCode", "message" => value}]}
       })
       when is_binary(value) do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,2}\z/, value),
         {code, ""} when code in 1..255 <- Integer.parse(value),
         do: {:ok, code},
         else: (_ -> :error)
  end

  defp status(_), do: :error
end
