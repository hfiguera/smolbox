defmodule SmolBox.Runtime.Clock do
  @moduledoc """
  Default managed-runtime clock. Hosts synchronize wall clocks across controllers.

  Absolute milliseconds survive restart; monotonic milliseconds bound observation
  within a process. A clock moving backward cannot extend an in-process stage.
  Custom clock modules for deterministic tests implement both functions.
  """
  @spec now() :: non_neg_integer()
  def now, do: System.system_time(:millisecond)
  @spec monotonic() :: integer()
  def monotonic, do: System.monotonic_time(:millisecond)
end
