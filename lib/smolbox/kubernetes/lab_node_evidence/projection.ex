defmodule SmolBox.Kubernetes.LabNodeEvidence.Projection do
  @moduledoc false
  defdelegate observation(value), to: SmolBox.Kubernetes.NodeEvidence.Projection
  defdelegate cleanup(value, receipt), to: SmolBox.Kubernetes.NodeEvidence.Projection
end
