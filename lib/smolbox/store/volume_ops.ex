defmodule SmolBox.Store.VolumeOps do
  @moduledoc false
  alias SmolBox.Embedded.{VolumeAttachment, VolumeAuthority}
  alias SmolBox.{Error, Mount, Validation, Volume}

  def accept(v, capacity, usage) do
    with :ok <- Volume.validate(v),
         true <-
           v.state == :creating and v.version == 1 and v.attached_to == nil and
             v.last_error == nil and v.request_version == nil,
         true <- is_integer(capacity[:disk_gb]) and usage.disk_gb + v.size_gb <= capacity.disk_gb,
         do: {:ok, v},
         else: (_ -> error(:admission_exhausted))
  end

  def change(v, version, action, now) do
    cond do
      not Validation.integer?(version, 1, 9_007_199_254_740_991) or not Validation.timestamp?(now) ->
        error(:validation)

      action in [:delete, :resolve_delete] and v.request_version == version ->
        {:ok, v, :existing}

      v.version != version ->
        error(:stale_version)

      true ->
        apply_change(v, action, now)
    end
  end

  defp apply_change(%{attached_to: nil, state: :ready} = v, :delete, now), do: deleting(v, now)

  defp apply_change(%{attached_to: nil, state: s} = v, :resolve_delete, now)
       when s in [:creating, :deleting, :unknown], do: deleting(v, now)

  defp apply_change(%{state: :creating, native_authority: nil} = v, {:complete, :ready}, now),
    do: save(v, %{state: :ready, last_error: nil}, now)

  defp apply_change(%{state: :deleting, native_authority: nil} = v, {:complete, :deleted}, now),
    do: save(v, %{state: :deleted, last_error: nil}, now)

  defp apply_change(%{state: :creating} = v, {:complete_native, outcome}, now),
    do: native_complete(v, outcome, ~w(provisioned), :ready, now)

  defp apply_change(%{state: :deleting} = v, {:complete_native, outcome}, now),
    do: native_complete(v, outcome, ~w(deleted aborted), :deleted, now)

  defp apply_change(%{state: s} = v, {:unknown, %Error{} = e}, now)
       when s in [:creating, :deleting],
       do: save(v, %{state: :unknown, last_error: %{e | evidence: :unknown}}, now)

  defp apply_change(_, _, _), do: error(:admission_exhausted)

  defp native_complete(v, outcome, statuses, state, now) do
    with %{"volume" => %{"status" => status}} <- outcome,
         true <- status in statuses,
         {:ok, authority} <- VolumeAuthority.complete(v.native_authority, v, outcome),
         do: save(v, %{state: state, native_authority: authority, last_error: nil}, now),
         else: (_ -> error(:identity_conflict))
  end

  defp deleting(v, now),
    do: save(v, %{state: :deleting, request_version: v.version, last_error: nil}, now)

  defp save(v, changes, now) do
    with {:ok, next} <- Volume.update(v, changes, now), do: {:ok, next, :changed}
  end

  # Called atomically with machine acceptance and publication of its durable record.
  def attach(machine, volumes, now) do
    Enum.reduce_while(
      machine.spec.volumes,
      {:ok, machine, volumes},
      &attach_reference(&1, &2, now)
    )
  end

  defp attach_reference(ref, {:ok, m, vs}, now) do
    key = {m.scope, ref.volume_id}

    case vs[key] do
      %Volume{state: :ready, attached_to: nil} = v -> attach_ready(v, ref, m, vs, now)
      nil -> {:halt, error(:not_found)}
      _ -> {:halt, error(:admission_exhausted)}
    end
  end

  defp attach_ready(v, ref, m, vs, now) do
    if m.volume_worker_id in [nil, v.worker_id] and compatible?(m, v) do
      case Volume.update(v, %{attached_to: {m.scope, m.id}}, now) do
        {:ok, v} ->
          mount = %Mount{source: Volume.path(v), target: ref.target, readonly: ref.readonly}

          {:cont,
           {:ok,
            %{
              m
              | volume_worker_id: v.worker_id,
                mounts: m.mounts ++ [mount],
                native_mounts: attachment(m, v, ref)
            }, Map.put(vs, Volume.key(v), v)}}

        e ->
          {:halt, e}
      end
    else
      {:halt, error(:identity_conflict)}
    end
  end

  defp compatible?(%{mounts: []}, _volume), do: true
  defp compatible?(%{native_mounts: []}, volume), do: volume.native_authority == nil

  defp compatible?(machine, %{native_authority: authority}) when authority != nil,
    do: hd(machine.native_mounts).binding == authority.binding

  defp compatible?(_, _), do: false

  defp attachment(machine, %{native_authority: nil}, _reference), do: machine.native_mounts

  defp attachment(machine, volume, reference) do
    {:ok, attachment} = VolumeAttachment.new(volume, reference)
    machine.native_mounts ++ [attachment]
  end

  # Release only after machine deletion, which already requires confirmed absence
  # or cancellation of an unassigned creation. Stopped/unknown machines keep holds.
  def release(%{state: :deleted} = m, volumes) do
    Enum.reduce_while(m.spec.volumes, {:ok, volumes}, &release_reference(&1, &2, m))
  end

  def release(_, volumes), do: {:ok, volumes}

  defp release_reference(ref, {:ok, vs}, m) do
    key = {m.scope, ref.volume_id}

    case vs[key] do
      %Volume{attached_to: owner} = v when owner == {m.scope, m.id} ->
        if release_matches?(m, ref, v),
          do: release_owned(v, vs, m.updated_at_ms),
          else: {:halt, error(:identity_conflict)}

      %Volume{} ->
        {:cont, {:ok, vs}}

      _ ->
        {:halt, error(:store)}
    end
  end

  defp release_matches?(%{native_mounts: []}, _reference, volume),
    do: volume.native_authority == nil

  defp release_matches?(machine, reference, volume),
    do:
      Enum.any?(machine.native_mounts, fn attachment ->
        attachment.volume_key == {machine.scope, reference.volume_id} and
          VolumeAttachment.matches?(attachment, volume)
      end)

  defp release_owned(v, vs, now) do
    case Volume.update(v, %{attached_to: nil}, now) do
      {:ok, next} -> {:cont, {:ok, Map.put(vs, Volume.key(v), next)}}
      error -> {:halt, error}
    end
  end

  defp error(category), do: {:error, %Error{category: category, operation: :volume}}
end
