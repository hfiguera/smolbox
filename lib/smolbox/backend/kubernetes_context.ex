defmodule SmolBox.Backend.KubernetesContext do
  @moduledoc false
  @enforce_keys [:config, :record]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
end
