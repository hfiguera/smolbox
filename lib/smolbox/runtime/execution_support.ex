defmodule SmolBox.Runtime.ExecutionSupport do
  @moduledoc false
  alias SmolBox.ExecutionFeatures
  alias SmolBox.Runtime.Session

  def check(config, spec) do
    with :ok <- file_capability(config, spec.profile), do: check_existing(config, spec)
  end

  defp file_capability(config, profile) do
    if SmolBox.FileAccess.extended?(profile) do
      case Session.store(config, :capabilities, []) do
        {:ok, %{guest_files: 1}} -> :ok
        {:ok, _unsupported} -> Session.error(:unsupported_capability, :submit)
        error -> error
      end
    else
      :ok
    end
  end

  defp check_existing(config, %{workload: %SmolBox.Workload{}} = spec) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_workloads: 1}} -> check_extended(config, spec)
      {:ok, _unsupported} -> Session.error(:unsupported_capability, :machine)
      error -> error
    end
  end

  defp check_existing(config, spec) do
    if ExecutionFeatures.interactive?(spec) do
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
    if ExecutionFeatures.extended?(spec) do
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
    do: not ExecutionFeatures.extended?(spec) or worker.runtime_version == "1.17.0"
end
