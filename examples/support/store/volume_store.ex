defmodule SmolBox.DurableHost.VolumeStore do
  @moduledoc false
  if Code.ensure_loaded?(SmolBox.Volume) do
    alias SmolBox.DurableHost.{Database, WorkerStore}
    alias SmolBox.{Error, Validation, Volume}
    alias SmolBox.Store.VolumeOps

    def capabilities(context) do
      Database.query(context, "SELECT payload FROM smolbox_volumes LIMIT 0", [])
      %{local_volumes: 1}
    end

    def accept(context, v, capacity) do
      with :ok <- Volume.validate(v) do
        case Database.read(context, Volume.key(v), :volume) do
          {:ok, %{fingerprint: fp} = current} when fp == v.fingerprint ->
            {:ok, current, :existing}

          {:ok, _} ->
            error(:identity_conflict)

          {:error, %{category: :not_found}} ->
            insert(context, v, capacity)

          e ->
            e
        end
      end
    end

    defp insert(context, v, capacity) do
      with :ok <- WorkerStore.admit(context, v.worker_id),
           {:ok, usage} <- Database.usage(context, v.worker_id),
           {:ok, v} <- VolumeOps.accept(v, capacity, usage),
           {:ok, saved} <- Database.write(context, v),
           do: {:ok, saved, :inserted}
    end

    def change(context, key, version, action, now) do
      with {:ok, v} <- Database.read(context, key, :volume),
           {:ok, next, result} <- VolumeOps.change(v, version, action, now),
           {:ok, saved} <- Database.write(context, next),
           do: {:ok, saved, result}
    end

    def list(context, scope, cursor, limit) do
      if Validation.identifier?(scope) and (cursor == nil or Validation.identifier?(cursor)) and
           Validation.integer?(limit, 1, 100),
         do: Database.machine_page(context, scope, cursor, limit, :volume),
         else: error(:validation)
    end

    def attach(context, m) do
      with {:ok, vs} <- references(context, m),
           {:ok, next, volumes} <- VolumeOps.attach(m, vs, m.accepted_at_ms),
           :ok <- admit(context, next),
           :ok <- save(context, volumes),
           do: {:ok, next}
    end

    defp admit(_, %{volume_worker_id: nil}), do: :ok
    defp admit(context, m), do: WorkerStore.admit(context, m.volume_worker_id)

    def release(context, %{state: :deleted} = m) do
      with {:ok, vs} <- references(context, m),
           {:ok, volumes} <- VolumeOps.release(m, vs),
           do: save(context, volumes)
    end

    def release(_, _), do: :ok

    defp references(context, m) do
      Enum.reduce_while(m.spec.volumes, {:ok, %{}}, fn ref, {:ok, vs} ->
        key = {m.scope, ref.volume_id}

        case Database.read(context, key, :volume) do
          {:ok, v} -> {:cont, {:ok, Map.put(vs, key, v)}}
          e -> {:halt, e}
        end
      end)
    end

    defp save(context, volumes) do
      Enum.reduce_while(volumes, :ok, fn {_, v}, :ok ->
        case Database.write(context, v) do
          {:ok, _} -> {:cont, :ok}
          e -> {:halt, e}
        end
      end)
    end

    defp error(c), do: {:error, %Error{category: c, operation: :volume}}
  else
    def capabilities(_), do: %{}
    def attach(_, m), do: {:ok, m}
    def release(_, _), do: :ok
  end
end
