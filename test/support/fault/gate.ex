defmodule SmolBox.FaultGate do
  @moduledoc false

  def hit(nil, _event, _phase), do: :ok

  def hit(gate, event, phase) do
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
        10_000 -> exit(:fault_gate_timeout)
      end
    end
  end

  defp notify(:stdio, event, phase), do: IO.puts("boundary:#{event}:#{phase}")
  defp notify(target, event, phase), do: send(target, {:boundary, event, phase, self()})
end
