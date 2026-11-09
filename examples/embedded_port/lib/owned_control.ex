defmodule SmolBox.Example.EmbeddedOwnedControl do
  @moduledoc """
  Normal, same-owner stop for a retained qualification machine. The original
  Runtime and helper epoch remain alive; no command result, disk repair or
  reservation release is inferred. Separate explicit resolution is required.
  """
  alias SmolBox.Backend.{EmbeddedContext, Reference}
  alias SmolBox.Embedded.Call
  alias SmolBox.Runtime.{NativeAuthority, Session, Target}

  alias SmolBox.{Backend, DiskExpansion, Error, Machines, Runtime}

  def stop(runtime, worker_id, key, version) do
    coordinator = Runtime.coordinator(runtime)

    Session.safe(fn -> coordinate_stop(coordinator, worker_id, runtime, key, version) end)
  end

  defp coordinate_stop(coordinator, worker_id, runtime, key, version) do
    with {:ok, config} <- GenServer.call(coordinator, :config),
         target when not is_nil(target) <-
           Enum.find(config.workers, &(&1.kind == :embedded and &1.id == worker_id)) do
      NativeAuthority.run(coordinator, target.id, fn ->
        owned_stop(config, Target.pin(target), runtime, key, version)
      end)
    else
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :stop)
    end
  end

  defp owned_stop(config, target, runtime, key, version) do
    %Reference{context: context} = target.connection
    bridge = EmbeddedContext.bridge(context)

    with {:ok, record} <- Machines.inspect(runtime, key),
         true <- record.version == version,
         true <- record.worker_id == target.id and record.state == :unknown,
         true <- record.created_machine != nil,
         :ok <- bridge.quiesce(context.server, context.epoch),
         {:ok, _lease} <-
           Session.store(config, :claim_worker, [
             target.id,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         :ok <- bridge.activate(context.server, target.domain_binding, context.epoch) do
      # Only this explicit action dispatches inside the frozen coordinator's
      # barrier, after the original epoch drains. Busy workers are not bypassed.
      dispatch_stop(target, record, context, bridge)
    else
      false -> Session.error(:stale_version, :stop)
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :stop)
    end
  end

  defp dispatch_stop(target, record, context, bridge) do
    stop_and_fence(target, record, context, bridge)
  rescue
    _ -> uncertain_stop()
  catch
    _, _ -> uncertain_stop()
  end

  defp stop_and_fence(target, record, context, bridge) do
    verify_stop(Target.connection(target, record), record, context)
  after
    # Always fence further dispatch, including when stop raises. A passive
    # observation can return busy after setting reconciling. Resolution drains
    # again; normal stop supplies no command Exit or reservation release.
    bridge.quiesce(context.server, context.epoch)
  end

  defp verify_stop(reference, record, context) do
    case Backend.stop(reference, record.machine_name) do
      {:ok, %{state: :stopped} = stopped} ->
        with true <- DiskExpansion.matches?(record, stopped),
             {:ok, health} <- Call.health(context, %{reference.budget | timeout_ms: 1000}),
             true <- health.epoch == context.epoch,
             do: {:ok, stopped},
             else: (_ -> uncertain_stop())

      {:error, %Error{}} = error ->
        error

      _ ->
        uncertain_stop()
    end
  end

  defp uncertain_stop,
    do: {:error, %Error{category: :unknown, operation: :stop, evidence: :dispatch_uncertain}}
end
