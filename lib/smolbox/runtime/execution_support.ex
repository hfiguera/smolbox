defmodule SmolBox.Runtime.ExecutionSupport do
  @moduledoc false
  alias SmolBox.Runtime.Session

  def interactive?(%{command: %SmolBox.Terminal.Spec{}}), do: true
  def interactive?(_spec), do: false

  def extended?(%{command: %SmolBox.Terminal.Spec{}}), do: true
  def extended?(%{command: %{background: true}}), do: true
  def extended?(%{profile: %{execution_ms: ms}}), do: is_integer(ms) and ms > 300_000
  def extended?(_invalid), do: false

  def check(config, %{workload: %SmolBox.Workload{}} = spec) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_workloads: 1}} -> check_extended(config, spec)
      {:ok, _unsupported} -> Session.error(:unsupported_capability, :machine)
      error -> error
    end
  end

  def check(config, spec) do
    if interactive?(spec) do
      case Session.store(config, :capabilities, []) do
        {:ok, %{interactive_terminal: 1, extended_execution: 1}} -> :ok
        {:ok, _unsupported} -> Session.error(:unsupported_capability, :terminal)
        error -> error
      end
    else
      check_extended(config, spec)
    end
  end

  defp check_extended(config, spec) do
    if extended?(spec) do
      case Session.store(config, :capabilities, []) do
        {:ok, %{extended_execution: 1}} -> :ok
        {:ok, _unsupported} -> Session.error(:unsupported_capability, :submit)
        error -> error
      end
    else
      :ok
    end
  end

  def worker?(worker, spec),
    do: not extended?(spec) or worker.runtime_version == "1.17.0"
end
