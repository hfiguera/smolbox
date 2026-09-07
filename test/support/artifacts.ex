defmodule SmolBox.TestArtifacts do
  @moduledoc false
  @behaviour SmolBox.ArtifactStore
  alias SmolBox.Error

  @impl SmolBox.ArtifactStore
  def read(store, scope, reference, max) do
    case Agent.get(store, &Map.get(&1, {scope, reference})) do
      bytes when is_binary(bytes) and byte_size(bytes) <= max -> {:ok, bytes}
      _missing -> {:error, %Error{category: :not_found, operation: :artifact_store}}
    end
  end

  @impl SmolBox.ArtifactStore
  def put(store, key, destination, bytes, digest) do
    Agent.get_and_update(store, fn entries ->
      id = {key, destination}

      case Map.get(entries, id) do
        nil ->
          {:ok, Map.put(entries, id, {bytes, digest})}

        {^bytes, ^digest} ->
          {:ok, entries}

        _conflict ->
          {{:error, %Error{category: :identity_conflict, operation: :artifact_store}}, entries}
      end
    end)
  end
end
