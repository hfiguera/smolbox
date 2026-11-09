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
  def activity(coordinator, id), do: GenServer.call(coordinator, {:native_activity, id})

  # A bounded operation on an already ready owner need not trigger startup
  # recovery of its siblings. Restore only the readiness captured atomically
  # before acquisition, after the caller verifies that same healthy owner.
  def operation(coordinator, id, function, same_ready_owner?) do
    operation(coordinator, id, fn was_ready ->
      result = function.()
      {result, was_ready and same_ready_owner?.()}
    end)
  end

  # A control that temporarily quiesces its bridge needs the atomic prior scan
  # state before deciding whether it may reactivate that same owner. The callback
  # returns the operation result and its independently checked readiness; it
  # cannot promote a scan that was incomplete at acquisition.
  def operation(coordinator, id, function) do
    with {:ok, was_ready} <- GenServer.call(coordinator, {:native_acquire_operation, id}) do
      try do
        {result, same_ready_owner?} = function.(was_ready)

        if was_ready and same_ready_owner? == true,
          do: GenServer.call(coordinator, {:native_ready, id})

        result
      after
        release(coordinator, id)
      end
    end
  end

  defp release(coordinator, id) do
    GenServer.call(coordinator, {:native_release, id})
  catch
    :exit, _ -> :ok
  end
end
