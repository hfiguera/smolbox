defmodule SmolBox.FaultArtifacts do
  @moduledoc false
  @behaviour SmolBox.ArtifactStore
  alias SmolBox.{FaultGate, TestArtifacts}

  @impl SmolBox.ArtifactStore
  def read(context, scope, reference, max) do
    adapter = Map.get(context, :adapter, TestArtifacts)
    adapter.read(context.store, scope, reference, max)
  end

  @impl SmolBox.ArtifactStore
  def put(context, key, destination, bytes, digest) do
    FaultGate.hit(context.faults, :artifact_put, :before)
    adapter = Map.get(context, :adapter, TestArtifacts)
    result = adapter.put(context.store, key, destination, bytes, digest)
    FaultGate.hit(context.faults, :artifact_put, :after)
    result
  end
end
