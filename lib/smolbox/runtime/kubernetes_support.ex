defmodule SmolBox.Runtime.KubernetesSupport do
  @moduledoc false
  alias SmolBox.Runtime.Session

  def verify(config) do
    if Enum.any?(config.workers, &match?(%{kind: :kubernetes}, &1)),
      do: Session.error(:unsupported_capability, :runtime),
      else: :ok
  end
end
