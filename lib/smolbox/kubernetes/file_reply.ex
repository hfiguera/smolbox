defmodule SmolBox.Kubernetes.FileReply do
  @moduledoc false
  alias SmolBox.{Files, Validation}
  alias SmolBox.Kubernetes.Shape

  @header 8192
  def overhead, do: @header + 8

  def decode(bytes, operation, path, max) do
    with <<"SBF1", size::32, rest::binary>> when size in 1..@header <- bytes,
         <<header::binary-size(^size), data::binary>> <- rest,
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(header, objects: :ordered_objects),
         object = Map.new(pairs),
         true <- map_size(object) == length(pairs),
         true <- Shape.exact_keys?(object, ~w(version operation path size sha256)),
         true <-
           object["version"] == 1 and object["operation"] == Atom.to_string(operation) and
             object["path"] == path,
         true <-
           Validation.integer?(object["size"], 0, max) and Validation.digest?(object["sha256"]),
         true <- payload?(operation, object, data),
         do: {:ok, object, data},
         else: (_ -> :error)
  end

  defp payload?(:upload, _object, <<>>), do: true

  defp payload?(:download, object, data),
    do: byte_size(data) == object["size"] and Files.sha256(data) == object["sha256"]

  defp payload?(_, _, _), do: false
end
