defmodule SmolBox.Store.MemoryVolumes do
  @moduledoc false
  alias SmolBox.{Error, Validation, Volume, WorkerControl}
  alias SmolBox.Store.{Codec, VolumeOps}

  def run({:fetch, key}, state), do: {fetch(state, key), state}

  def run({:list, scope, cursor, limit}, state) do
    if Validation.identifier?(scope) and (cursor == nil or Validation.identifier?(cursor)) and
         Validation.integer?(limit, 1, 100) do
      records =
        state.volumes
        |> Map.values()
        |> Enum.filter(&(&1.scope == scope and (cursor == nil or &1.id > cursor)))
        |> Enum.sort_by(& &1.id)

      page = Enum.take(records, limit)
      {{:ok, page, if(length(records) > limit, do: List.last(page).id)}, state}
    else
      {error(:validation), state}
    end
  end

  def run({:accept, v, capacity, usage}, state) do
    case fetch(state, Volume.key(v)) do
      {:ok, %{fingerprint: fp} = existing} when fp == v.fingerprint ->
        {{:ok, existing, :existing}, state}

      {:ok, _} ->
        {error(:identity_conflict), state}

      {:error, %{category: :not_found}} ->
        with :ok <-
               WorkerControl.admit(
                 Map.get(state.worker_controls, v.worker_id, WorkerControl.initial(v.worker_id))
               ),
             {:ok, v} <- VolumeOps.accept(v, capacity, usage),
             {:ok, next} <- persist(state, Map.put(state.volumes, Volume.key(v), v)),
             do: {{:ok, v, :inserted}, next},
             else: (e -> {e, state})
    end
  end

  def run({:change, key, version, action, now}, state) do
    with {:ok, v} <- fetch(state, key),
         {:ok, next, result} <- VolumeOps.change(v, version, action, now),
         {:ok, state} <- persist(state, Map.put(state.volumes, key, next)),
         do: {{:ok, next, result}, state},
         else: (e -> {e, state})
  end

  defp fetch(state, key) do
    case Map.fetch(state.volumes, key) do
      {:ok, v} -> {:ok, v}
      :error -> error(:not_found)
    end
  end

  def persist(state, volumes) do
    if map_size(state.records) + map_size(state.machines) + map_size(volumes) <= state.max_records do
      Enum.reduce_while(volumes, {:ok, state}, &persist_one/2)
    else
      error(:admission_exhausted)
    end
  end

  defp persist_one({key, v}, {:ok, s}) do
    if Map.get(s.volumes, key) == v, do: {:cont, {:ok, s}}, else: encode_one(key, v, s)
  end

  defp encode_one(key, v, s) do
    with {:ok, bytes} <- Codec.encode(v),
         total = s.bytes - Map.get(s.sizes, {:volume, key}, 0) + byte_size(bytes),
         true <- total <= s.max_bytes do
      {:cont,
       {:ok,
        %{
          s
          | volumes: Map.put(s.volumes, key, v),
            bytes: total,
            sizes: Map.put(s.sizes, {:volume, key}, byte_size(bytes))
        }}}
    else
      _ -> {:halt, error(:admission_exhausted)}
    end
  end

  defp error(c), do: {:error, %Error{category: c, operation: :volume}}
end
