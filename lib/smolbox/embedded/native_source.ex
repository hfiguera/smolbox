defmodule SmolBox.Embedded.NativeSource do
  @moduledoc false
  alias SmolBox.Embedded.{MountContract, Shape}
  alias SmolBox.Source

  # Durable source intent is separate from prepared metadata and a wire request.
  # Validation supplies neither catalog approval nor native dispatch authority.
  def artifact?(artifact), do: match?({:ok, %Source{kind: :oci}}, Source.from_artifact(artifact))

  def registry_artifact?(artifact),
    do: match?({:ok, %Source{kind: :registry}}, Source.from_artifact(artifact))

  def creation?(creation) do
    creation_shape?(creation, &artifact?/1)
  end

  def registry_creation?(creation), do: creation_shape?(creation, &registry_artifact?/1)

  defp creation_shape?(creation, source?) do
    keys = ~w(name owner_token incarnation source resources labels)

    MountContract.creation_keys?(creation, keys, 2) and
      Shape.id?(creation["name"]) and Shape.hex?(creation["owner_token"], 64) and
      Shape.hex?(creation["incarnation"], 32) and source?.(creation["source"]) and
      Shape.resources?(creation["resources"]) and creation["labels"] == %{}
  end

  def matches?(creation, artifact),
    do: (creation?(creation) or registry_creation?(creation)) and creation["source"] == artifact
end
