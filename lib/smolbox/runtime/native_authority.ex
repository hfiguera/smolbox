defmodule SmolBox.Runtime.NativeAuthority do
  @moduledoc false

  # Serialize automatic reconciliation and explicit resolution, outside the
  # coordinator. A dead holder is released but leaves dispatch frozen.
  def run(coordinator, id, function) do
    with :ok <- GenServer.call(coordinator, {:native_acquire, id}) do
      try do
        function.()
      after
        release(coordinator, id)
      end
    end
  end

  def available?(coordinator, id), do: GenServer.call(coordinator, {:native_available, id})

  defp release(coordinator, id) do
    GenServer.call(coordinator, {:native_release, id})
  catch
    :exit, _ -> :ok
  end
end
