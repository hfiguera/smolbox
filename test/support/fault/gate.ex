defmodule SmolBox.FaultGate do
  @moduledoc false

  def hit(gate, event, phase, hold_ms \\ 10_000)

  def hit(nil, _event, _phase, _hold_ms), do: :ok

  def hit(gate, event, phase, hold_ms) do
    target =
      Agent.get_and_update(gate, fn
        %{event: ^event, phase: ^phase, fired: false, observer: observer} = state ->
          {observer, %{state | fired: true}}

        state ->
          {nil, state}
      end)

    if target do
      notify(target, event, phase)

      receive do
        :release_boundary -> :ok
      after
        hold_ms -> exit(:fault_gate_timeout)
      end
    end
  end

  defp notify(:stdio, event, phase), do: IO.puts("boundary:#{event}:#{phase}")
  defp notify(target, event, phase), do: send(target, {:boundary, event, phase, self()})
end
