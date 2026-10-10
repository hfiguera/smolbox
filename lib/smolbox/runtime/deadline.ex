defmodule SmolBox.Runtime.Deadline do
  @moduledoc false

  # Persist wall deadlines, but never extend an attempt when the wall clock rolls back.
  @spec remaining(module(), integer(), {integer(), integer()}) :: integer()
  def remaining(clock, deadline, {wall, monotonic}),
    do: deadline - max(clock.now(), wall + clock.monotonic() - monotonic)
end
