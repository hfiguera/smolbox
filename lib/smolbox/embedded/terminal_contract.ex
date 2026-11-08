defmodule SmolBox.Embedded.TerminalContract do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Terminal.{Result, Spec}
  alias SmolBox.Validation
  @max 9_007_199_254_740_991
  def max_sequence, do: @max

  def limits,
    do: %{
      "session_ms" => 86_400_000,
      "buffer_bytes" => 1_048_576,
      "input_bytes" => 65_536,
      "total_input_bytes" => 16_777_216,
      "attach_ms" => 30_000,
      "close_ms" => 5000,
      "input_slots" => 2,
      "output_events" => 1024,
      "descriptors" => 20
    }

  def spec?(spec) do
    Shape.keys?(
      spec,
      ~w(program cols rows session_ms idle_ms attach_ms close_ms max_buffer_bytes max_input_bytes total_input_bytes)
    ) and
      Shape.text?(spec["program"], 4096, false) and
      Spec.dimensions?(spec["cols"], spec["rows"]) and
      ranges?(spec)
  end

  defp ranges?(spec),
    do:
      Enum.all?(
        [
          {"session_ms", 1000, 86_400_000},
          {"idle_ms", 1000, spec["session_ms"]},
          {"attach_ms", 100, 30_000},
          {"close_ms", 1, 5000},
          {"max_buffer_bytes", 1024, 1_048_576},
          {"max_input_bytes", 1, 65_536},
          {"total_input_bytes", 1, 16_777_216}
        ],
        fn {key, low, high} -> Validation.integer?(spec[key], low, high) end
      )

  def action?(%{"action" => action} = control) when action in ~w(attach close),
    do: Shape.keys?(control, ~w(action))

  def action?(%{"action" => "resize"} = control),
    do:
      Shape.keys?(control, ~w(action cols rows)) and
        Spec.dimensions?(control["cols"], control["rows"])

  def action?(%{"action" => "input"} = control),
    do:
      Shape.keys?(control, ~w(action data_base64)) and
        match?({:ok, _}, Shape.chunk(control["data_base64"]))

  def action?(_control), do: false

  def outcome?(outcome) do
    Shape.keys?(
      outcome,
      ~w(result completion dispatch observed_exit worker_collected output_bytes)
    ) and
      outcome["completion"] in ~w(exited cancelled deadline output_limit consumer_lost native_error unknown) and
      outcome["dispatch"] in ~w(not_dispatched may_have_dispatched) and
      is_boolean(outcome["worker_collected"]) and
      Shape.optional?(
        outcome["observed_exit"],
        &Validation.integer?(&1, -2_147_483_648, 2_147_483_647)
      ) and
      Validation.integer?(outcome["output_bytes"], 0, @max) and
      exit_evidence?(outcome) and dispatch_evidence?(outcome)
  end

  defp exit_evidence?(%{"completion" => "exited"} = outcome),
    do:
      outcome["worker_collected"] and Result.valid?(%Result{exit_code: outcome["observed_exit"]})

  defp exit_evidence?(_outcome), do: true

  defp dispatch_evidence?(%{"dispatch" => "not_dispatched"} = outcome),
    do: outcome["observed_exit"] == nil and outcome["output_bytes"] == 0

  defp dispatch_evidence?(_outcome), do: true

  def control(pending, sequence, control) do
    spec = pending.operation["terminal"]

    with true <- pending.terminal_opened and not pending.terminal_closed,
         true <- sequence == pending.terminal_control + 1 and action?(control),
         {:ok, charge, attached, closed} <- charge(pending, control),
         true <- charge <= spec["total_input_bytes"] - pending.terminal_input do
      {:ok,
       %{
         pending
         | terminal_control: sequence,
           terminal_input: pending.terminal_input + charge,
           terminal_attached: attached,
           terminal_closed: closed
       }}
    else
      _ -> :error
    end
  end

  defp charge(%{terminal_attached: false}, %{"action" => "attach"}), do: {:ok, 0, true, false}

  defp charge(%{terminal_attached: true} = pending, %{"action" => "input", "data_base64" => data}) do
    with {:ok, bytes} <- Shape.chunk(data),
         true <- byte_size(bytes) <= pending.operation["terminal"]["max_input_bytes"],
         do: {:ok, byte_size(bytes), true, false},
         else: (_ -> :error)
  end

  defp charge(%{terminal_attached: true}, %{"action" => "resize"}), do: {:ok, 4, true, false}
  defp charge(%{terminal_attached: true}, %{"action" => "close"}), do: {:ok, 0, true, true}
  defp charge(_pending, _control), do: :error
end
