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
         :ok <- admission(w, spec, mode) do
      {:cont, :ok}
    else
      false -> {:halt, error(:unsupported_capability)}
      e -> {:halt, e}
    end
  end

  defp admission(%{draining: true}, _spec, :new), do: error(:admission_exhausted)
  defp admission(worker, spec, :new), do: mount_budget(worker, spec)
  defp admission(_, _, _), do: :ok

  # The 1.22.0 x86_64 bundle has a fixed virtio IRQ budget. Prepared packs
  # include a pack share, and filtering or forwarding adds a virtio-net device.
  def mount_budget(
        %{platform: :linux, architecture: "x86_64"} = worker,
        %{volumes: [_ | _] = mounts} = spec
      ) do
    if Target.sdk_version(worker) == "1.22.0" and length(mounts) > mount_limit(spec),
      do:
        {:error,
         %Error{category: :unsupported_capability, operation: :create, evidence: :not_dispatched}},
      else: :ok
  end

  def mount_budget(_worker, _spec), do: :ok

  defp mount_limit(%{artifact: %{"kind" => "oci"}}), do: 2
  defp mount_limit(%{profile: %{network: :offline}, ports: []}), do: 2
  defp mount_limit(_prepared), do: 1

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
