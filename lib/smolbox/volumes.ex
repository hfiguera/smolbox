defmodule SmolBox.Volumes do
  @moduledoc """
  Managed local volumes independent of machine lifetime. Hosts authorize scopes.

  Creation and deletion persist intent before the worker mutation. These calls
  observe one attempt; caller/controller loss can leave `:creating`, `:deleting`
  or `:unknown` outcomes, never automatically replayed. Inspect durable records
  after restart. `resolve_delete/4` removes uncertain storage only after the host
  fences all pending requests. There is no adoption by ID or path.

  Machines refer to volume IDs through `SmolBox.VolumeMount`. Attachments are
  exclusive even for read-only mounts and remain through stop and uncertainty.
  Verified machine deletion releases attachment, but retains volume and budget.
  """
  alias SmolBox.{Client, Error, Runtime, Validation, Volume, VolumePolicy}
  alias SmolBox.Runtime.Session

  alias SmolBox.Runtime.VolumeAccess

  @spec create(SmolBox.runtime(), keyword()) :: {:ok, Volume.key()} | {:error, Error.t()}
  def create(runtime, options) do
    with true <- Validation.keys?(options, [:scope, :id, :worker_id, :size_gb]),
         true <- Enum.all?([:scope, :id, :worker_id], &Validation.identifier?(options[&1])),
         true <- Validation.integer?(options[:size_gb], 1, 1024),
         {:ok, config} <- configuration(runtime),
         {:ok, worker} <- VolumeAccess.worker(config, options[:worker_id]),
         true <- VolumePolicy.valid?(worker.volume_policy) do
      now = config.clock.now()

      fingerprint =
        :crypto.mac(
          :hmac,
          :sha256,
          config.fingerprint_key,
          :erlang.term_to_binary({"smolbox-volume-v1", Enum.sort(options), worker.volume_policy})
        )
        |> Base.encode16(case: :lower)

      v =
        struct!(
          Volume,
          Map.merge(Map.new(options), %{
            worker_volume_id:
              "sbv-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
            policy: worker.volume_policy,
            fingerprint: fingerprint,
            accepted_at_ms: now,
            updated_at_ms: now
          })
        )

      case accept(config, worker, v) do
        {:ok, saved, :existing} -> {:ok, Volume.key(saved)}
        {:ok, saved, :inserted} -> provision(config, worker, saved)
        error -> error
      end
    else
      false -> error(:validation)
      error -> error
    end
  end

  defp accept(config, %{draining: true}, v) do
    case Session.store(config, :volume_fetch, [Volume.key(v)]) do
      {:ok, %{fingerprint: fp} = existing} when fp == v.fingerprint -> {:ok, existing, :existing}
      {:ok, _} -> error(:identity_conflict)
      {:error, %{category: :not_found}} -> error(:admission_exhausted)
      e -> e
    end
  end

  defp accept(config, worker, v), do: Session.store(config, :volume_accept, [v, worker.capacity])

  defp provision(config, worker, v) do
    result =
      case Client.provision_volume(worker.client, v.worker_volume_id, v.size_gb) do
        {:ok, path} ->
          if path == Volume.path(v),
            do: {:complete, :ready},
            else: {:unknown, %Error{category: :identity_conflict, operation: :volume}}

        {:error, e} ->
          {:unknown, %{e | operation: :volume}}
      end

    with {:ok, saved, _} <-
           Session.store(config, :volume_change, [
             Volume.key(v),
             v.version,
             result,
             config.clock.now()
           ]),
         do: {:ok, Volume.key(saved)}
  end

  @doc "Fetch a durable volume, including its current attachment and retained deletion history."
  @spec inspect(SmolBox.runtime(), Volume.key()) :: {:ok, Volume.t()} | {:error, Error.t()}
  def inspect(runtime, {scope, id} = key) do
    with true <- Validation.identifier?(scope) and Validation.identifier?(id),
         {:ok, config} <- configuration(runtime),
         do: Session.store(config, :volume_fetch, [key]),
         else: (
           false -> error(:validation)
           e -> e
         )
  end

  def inspect(_, _), do: error(:validation)

  @doc "List this scope's durable volume records, including deleted identities."
  @spec list(SmolBox.runtime(), String.t(), keyword()) ::
          {:ok, [Volume.t()], String.t() | nil} | {:error, Error.t()}
  def list(runtime, scope, options \\ []) do
    with true <- Validation.keys?(options, [:cursor, :limit]),
         {:ok, config} <- configuration(runtime),
         do:
           Session.store(config, :volume_list, [
             scope,
             options[:cursor],
             Keyword.get(options, :limit, 50)
           ]),
         else: (
           false -> error(:validation)
           e -> e
         )
  end

  @doc "Explicitly delete a ready, unattached volume using the inspected version. Never deletes a machine."
  @spec delete(SmolBox.runtime(), Volume.key(), pos_integer()) ::
          {:ok, Volume.t()} | {:error, Error.t()}
  def delete(runtime, key, version), do: remove(runtime, key, version, :delete)

  @doc """
  Resolve an uncertain provisioning/deletion attempt by deleting its backing storage.
  Requires `[quiesced: true]`: the host must fence pending upstream requests first.
  An expired store claim, controller restart or stopped VM is insufficient.
  Success requires the worker's deletion acknowledgment. No ready adoption or
  automatic replay is supported because upstream has no volume inspection API.
  """
  @spec resolve_delete(SmolBox.runtime(), Volume.key(), pos_integer(), keyword()) ::
          {:ok, Volume.t()} | {:error, Error.t()}
  def resolve_delete(runtime, key, version, options) do
    if options == [quiesced: true],
      do: remove(runtime, key, version, :resolve_delete),
      else: error(:validation)
  end

  defp remove(runtime, key, version, action) do
    with {:ok, v} <- __MODULE__.inspect(runtime, key),
         {:ok, config} <- configuration(runtime),
         {:ok, worker} <- VolumeAccess.worker(config, v.worker_id),
         true <- worker.volume_policy == v.policy,
         {:ok, intent, status} <-
           Session.store(config, :volume_change, [key, version, action, config.clock.now()]) do
      delete_attempt(config, worker, intent, status)
    else
      false -> error(:identity_conflict)
      e -> e
    end
  end

  defp delete_attempt(_, _, intent, :existing), do: {:ok, intent}

  defp delete_attempt(config, worker, intent, :changed) do
    result =
      case Client.delete_volume(worker.client, intent.worker_volume_id) do
        :ok -> {:complete, :deleted}
        {:error, e} -> {:unknown, e}
      end

    with {:ok, saved, _} <-
           Session.store(config, :volume_change, [
             Volume.key(intent),
             intent.version,
             result,
             config.clock.now()
           ]),
         do: {:ok, saved}
  end

  defp configuration(runtime) do
    with {:ok, config} <- GenServer.call(Runtime.coordinator(runtime), :config),
         true <- config.managed_machines,
         :ok <- VolumeAccess.capable(config),
         do: {:ok, config},
         else: (
           false -> error(:unsupported_capability)
           e -> e
         )
  rescue
    _ -> error(:unknown)
  catch
    :exit, _ -> error(:unknown)
  end

  defp error(category), do: {:error, %Error{category: category, operation: :volume}}
end
