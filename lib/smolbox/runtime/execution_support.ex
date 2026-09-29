defmodule SmolBox.Runtime.ExecutionSupport do
  @moduledoc false
  alias SmolBox.ExecutionFeatures
  alias SmolBox.Runtime.Session

  def check(config, spec) do
    with :ok <- capture_capability(config, spec),
         :ok <- image_capability(config, spec),
         :ok <- source_capability(config, spec),
         :ok <- file_capability(config, spec.profile),
         do: check_existing(config, spec)
  end

  defp capture_capability(config, %{checkpointable: true}) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_checkpoints: 1}} -> :ok
      {:ok, _} -> Session.error(:unsupported_capability, :checkpoint)
      error -> error
    end
  end

  defp capture_capability(_config, _spec), do: :ok

  defp image_capability(config, %{command: %SmolBox.ImagePull{}}) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_images: 1}} -> :ok
      {:ok, _unsupported} -> Session.error(:unsupported_capability, :pull_image)
      error -> error
    end
  end

  defp image_capability(_config, _spec), do: :ok

  defp source_capability(config, spec) do
    if SmolBox.Source.remote?(spec.artifact) do
      case Session.store(config, :capabilities, []) do
        {:ok, %{registry_sources: 1}} -> :ok
        {:ok, _unsupported} -> Session.error(:unsupported_capability, :source)
        error -> error
      end
    else
      :ok
    end
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
    do:
      not ExecutionFeatures.extended?(spec) or
        worker.runtime_version in ["1.17.0", "1.19.0", "1.20.2"]
end
