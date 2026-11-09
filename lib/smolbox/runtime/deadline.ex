defmodule SmolBox.Runtime.Deadline do
  @moduledoc false

  # Persist wall deadlines, but never extend an attempt when the wall clock rolls back.
  @spec remaining(module(), integer(), {integer(), integer()}) :: integer()
  def remaining(clock, deadline, {wall, monotonic}),
    do: deadline - max(clock.now(), wall + clock.monotonic() - monotonic)

  def remaining(deadline, operation) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: {:ok, timeout},
      else: {:error, %SmolBox.Error{category: :expired, operation: operation}}
  end
end
