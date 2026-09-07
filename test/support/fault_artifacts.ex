defmodule SmolBox.FaultArtifacts do
  @moduledoc false
  @behaviour SmolBox.ArtifactStore
  alias SmolBox.{FaultGate, TestArtifacts}

  @impl SmolBox.ArtifactStore
  def read(context, scope, reference, max),
    do: TestArtifacts.read(context.store, scope, reference, max)

  @impl SmolBox.ArtifactStore
  def put(context, key, destination, bytes, digest) do
    FaultGate.hit(context.faults, :artifact_put, :before)
    result = TestArtifacts.put(context.store, key, destination, bytes, digest)
    FaultGate.hit(context.faults, :artifact_put, :after)
    result
  end
end
