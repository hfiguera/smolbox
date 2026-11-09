defmodule SmolBox.Runtime.VolumeAttempt do
  @moduledoc false
  alias SmolBox.{Backend, Error, Runtime, Validation, Volume}
  alias SmolBox.Backend.{Binding, Budget, EmbeddedContext, EmbeddedVolume}
  alias SmolBox.Embedded.{Call, VolumeAuthority}
  alias SmolBox.Runtime.{NativeAuthority, Session, Target}

  def run(runtime, config, %{kind: :embedded} = worker, mode, function) do
    Session.safe(fn -> protected(runtime, config, worker, mode, function) end)
  end

  def run(_runtime, _config, worker, _mode, function), do: function.(worker, nil)

  defp protected(runtime, config, worker, mode, function) do
    deadline =
      System.monotonic_time(:millisecond) + min(worker.connection.budget.timeout_ms, 86_400_000)

    worker = Target.pin(worker)

    attempt = fn -> owned(config, worker, mode, deadline, function) end

    if mode == :resolve_delete,
      do: NativeAuthority.run(Runtime.coordinator(runtime), worker.id, attempt),
      else:
        NativeAuthority.operation(Runtime.coordinator(runtime), worker.id, attempt, fn ->
          same_ready_owner?(worker, deadline)
        end)
  end

  defp same_ready_owner?(worker, deadline) do
    context = worker.connection.context

    with {:ok, budget} <- remaining(worker.connection.budget, deadline),
         {:ok, %{status: :ready, epoch: epoch}} <-
           Call.health(context, %{budget | timeout_ms: min(budget.timeout_ms, 1000)}),
         do: epoch == context.epoch,
         else: (_ -> false)
  end

  defp owned(config, worker, mode, deadline, function) do
    with true <- live_pin?(worker),
         {:ok, _lease} <-
           Session.store(config, :claim_worker, [
             worker.id,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         :ok <- fence(worker, mode, deadline),
         {:ok, _budget} <- remaining(worker.connection.budget, deadline),
         do: function.(worker, deadline),
         else: (
           {:error, %Error{} = failure} ->
             {:error, %{failure | operation: :volume, evidence: :not_dispatched}}

           _ ->
             error(:unknown, :not_dispatched)
         )
  end

  def authority(%{kind: :embedded, domain_binding: binding}),
    do: %VolumeAuthority{binding: struct!(Binding, binding)}

  def authority(_worker), do: nil

  def existing(config, %{kind: :embedded} = worker, volume) do
    case Session.store(config, :volume_fetch, [Volume.key(volume)]) do
      {:ok, %{fingerprint: fingerprint} = saved} when fingerprint == volume.fingerprint ->
        if bound?(worker, saved),
          do: {:ok, saved},
          else: error(:identity_conflict, :not_dispatched)

      {:ok, _} ->
        error(:identity_conflict, :not_dispatched)

      {:error, %Error{category: :not_found}} ->
        :new

      error ->
        error
    end
  end

  def existing(_config, _worker, _volume), do: :new

  def repeated?(%{kind: :embedded}, volume, version),
    do:
      Validation.integer?(version, 1, 9_007_199_254_740_991) and volume.request_version == version

  def repeated?(_worker, _volume, _version), do: false

  def fingerprint_input(worker, options) do
    case authority(worker) do
      nil ->
        {"smolbox-volume-v1", Enum.sort(options), worker.volume_policy}

      authority ->
        {"smolbox-volume-v2", Enum.sort(options), worker.volume_policy, authority.binding}
    end
  end

  def bound?(worker, volume) do
    volume.worker_id == Target.id(worker) and volume.policy == worker.volume_policy and
      case authority(worker) do
        nil ->
          volume.native_authority == nil

        expected ->
          volume.native_authority != nil and volume.native_authority.binding == expected.binding
      end
  end

  def provision(worker, volume, deadline) do
    if volume.native_authority == nil do
      case Backend.provision_volume(
             Target.connection(worker),
             volume.worker_volume_id,
             volume.size_gb
           ) do
        {:ok, path} when path == volume.policy.root <> "/" <> volume.worker_volume_id ->
          {:complete, :ready}

        {:error, %Error{} = error} ->
          {:unknown, %{error | operation: :volume}}

        _ ->
          {:unknown, conflict()}
      end
    else
      complete(invoke(worker, volume, %{"action" => "provision"}, deadline))
    end
  end

  def delete(worker, volume, mode, deadline) do
    if volume.native_authority == nil do
      case Backend.delete_volume(Target.connection(worker), volume.worker_volume_id) do
        :ok -> {:complete, :deleted}
        {:error, %Error{} = error} -> {:unknown, error}
        _ -> {:unknown, conflict()}
      end
    else
      result =
        if mode == :resolve_delete,
          do: cleanup(volume, &invoke(worker, volume, &1, deadline)),
          else: invoke(worker, volume, %{"action" => "delete"}, deadline)

      complete(result)
    end
  end

  # This is explicit fenced cleanup, never automatic reconciliation/replay.
  # Only a known pre-dispatch ownership rejection can select unready staging.
  def cleanup(volume, invoke) do
    case invoke.(%{"action" => "resolve_deletion", "quiesced" => true}) do
      {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} = error ->
        if volume.native_authority.provision == nil,
          do: invoke.(%{"action" => "abort_staging", "quiesced" => true}),
          else: error

      result ->
        result
    end
  end

  def finish(config, volume, result),
    do:
      Session.store(config, :volume_change, [
        Volume.key(volume),
        volume.version,
        result,
        config.clock.now()
      ])

  defp invoke(worker, volume, action, deadline) do
    with {:ok, budget} <- remaining(worker.connection.budget, deadline) do
      reference = Target.connection(worker, volume)
      EmbeddedVolume.run(reference.context, action, budget)
    end
  end

  defp complete({:ok, outcome}), do: {:complete_native, outcome}
  defp complete({:error, %Error{} = error}), do: {:unknown, %{error | operation: :volume}}
  defp complete(_), do: {:unknown, conflict()}

  defp remaining(budget, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: Budget.constrain(budget, timeout_ms: remaining),
      else: error(:expired, :not_dispatched)
  end

  defp live_pin?(worker),
    do:
      worker.connection.context.pinned and is_pid(worker.connection.context.server) and
        is_binary(worker.connection.context.epoch)

  defp fence(worker, :resolve_delete, _deadline) do
    context = worker.connection.context
    EmbeddedContext.bridge(context).quiesce(context.server, context.epoch)
  end

  defp fence(worker, _mode, deadline) do
    if same_ready_owner?(worker, deadline),
      do: :ok,
      else: error(:unknown, :not_dispatched)
  end

  defp conflict,
    do: %Error{category: :identity_conflict, operation: :volume, evidence: :dispatch_uncertain}

  defp error(category, evidence),
    do: {:error, %Error{category: category, operation: :volume, evidence: evidence}}
end
