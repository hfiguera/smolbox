defmodule SmolBox.ExecutionFeatures do
  @moduledoc false

  # Pure specification classification shared by persistence and runtime admission.
  # The legacy budget boundary is also part of the stored record format selection.
  @spec interactive?(term()) :: boolean()
  def interactive?(%{command: %SmolBox.Terminal.Spec{}}), do: true
  def interactive?(_spec), do: false

  @spec extended?(term()) :: boolean()
  def extended?(%{command: %SmolBox.Terminal.Spec{}}), do: true
  def extended?(%{command: %{background: true}}), do: true
  def extended?(%{profile: %{execution_ms: ms}}), do: is_integer(ms) and ms > 300_000
  def extended?(_invalid), do: false
end
