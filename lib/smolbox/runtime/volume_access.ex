defmodule SmolBox.Runtime.VolumeAccess do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Runtime.Session

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
         true <- w.volume_policy == v.policy and Target.supports?(w, spec),
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
    case Enum.find(config.workers, &(Target.id(&1) == id)) do
      %{platform: :linux} = worker ->
        with true <- Target.supports_feature?(worker, :volumes),
             :ok <- native_reader(config, worker),
             do: {:ok, worker},
             else: (_ -> error(:unsupported_capability))

      _ ->
        error(:unsupported_capability)
    end
  end

  defp native_reader(%{store: {adapter, _}} = config, %{kind: :embedded}) do
    with {:ok, %{local_volumes: 1, native_volumes: 1}} <- Session.store(config, :capabilities, []),
         true <-
           Enum.all?(
             [volume_accept: 3, volume_fetch: 2, volume_list: 4, volume_change: 5],
             fn {name, arity} -> function_exported?(adapter, name, arity) end
           ),
         do: :ok,
         else: (_ -> error(:unsupported_capability))
  end

  defp native_reader(_config, _worker), do: :ok

  defp error(category), do: {:error, %Error{category: category, operation: :volume}}
end
