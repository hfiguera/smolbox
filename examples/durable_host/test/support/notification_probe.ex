defmodule SmolBox.DurableHost.NotificationProbe do
  @moduledoc false
  alias SmolBox.FaultGate

  def attach(gate) do
    :telemetry.attach(
      __MODULE__,
      [:smolbox, :execution, :updated],
      &__MODULE__.deliver/4,
      gate
    )
  end

  def deliver(_event, _measurements, %{evidence: :exited}, gate) do
    FaultGate.hit(gate, :notification, :before)
    IO.puts("notification:delivered")
    FaultGate.hit(gate, :notification, :after)
  end

  def deliver(_event, _measurements, _metadata, _gate), do: :ok
end
