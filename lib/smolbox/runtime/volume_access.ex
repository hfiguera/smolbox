defmodule SmolBox.Runtime.VolumeAccess do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Runtime.{Session, WorkerConfig}

  @doc false
  def approved(config, spec, mode \\ :existing)
  def approved(_, %{volumes: []}, _), do: :ok

  def approved(config, spec, mode) do
    with :ok <- capable(config) do
      Enum.reduce_while(spec.volumes, :ok, &approve_reference(config, spec, mode, &1, &2))
    end
  end

  defp approve_reference(config, spec, mode, ref, :ok) do
    with {:ok, v} <- Session.store(config, :volume_fetch, [{spec.scope, ref.volume_id}]),
         {:ok, w} <- worker(config, v.worker_id),
         true <- w.volume_policy == v.policy and WorkerConfig.supports?(w, spec),
         :ok <- admission(w, mode) do
      {:cont, :ok}
    else
      false -> {:halt, error(:unsupported_capability)}
      e -> {:halt, e}
    end
  end

  defp admission(%{draining: true}, :new), do: error(:admission_exhausted)
  defp admission(_, _), do: :ok

  def capable(config) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{local_volumes: 1}} -> :ok
      {:ok, _} -> error(:unsupported_capability)
      e -> e
    end
  end

  def worker(config, id) do
    case Enum.find(config.workers, &(&1.client.worker.id == id)) do
      %{runtime_version: version, platform: :linux} = w when version in ["1.20.2", "1.22.0"] ->
        {:ok, w}

      _ ->
        error(:unsupported_capability)
    end
  end

  defp error(category), do: {:error, %Error{category: category, operation: :volume}}
end
