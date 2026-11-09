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
    deadline = now() + 30_000

    Session.safe(fn ->
      coordinate_stop(coordinator, worker_id, runtime, key, version, deadline)
    end)
  end

  defp coordinate_stop(coordinator, worker_id, runtime, key, version, deadline) do
    with {:ok, config} <- GenServer.call(coordinator, :config),
         target when not is_nil(target) <-
           Enum.find(config.workers, &(&1.kind == :embedded and &1.id == worker_id)) do
      deadline = min(deadline, now() + Target.connection(target).budget.timeout_ms)

      NativeAuthority.run(coordinator, target.id, fn ->
        pin_and_stop(config, target, runtime, key, version, deadline)
      end)
    else
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :stop)
    end
  end

  defp pin_and_stop(config, target, runtime, key, version, deadline) do
    with {:ok, remaining} <- remaining(deadline) do
      reference = Target.connection(target)

      bounded = %{
        target
        | connection: %{
            reference
            | budget: %{
                reference.budget
                | timeout_ms: min(reference.budget.timeout_ms, remaining)
              }
          }
      }

      owned_stop(config, Target.pin(bounded), runtime, key, version, deadline)
    end
  end

  defp owned_stop(config, target, runtime, key, version, deadline) do
    %Reference{context: context} = target.connection
    bridge = EmbeddedContext.bridge(context)

    with {:ok, record} <- Machines.inspect(runtime, key),
         true <- record.version == version,
         true <- record.worker_id == target.id and record.state == :unknown,
         true <- record.created_machine != nil,
         :ok <- await_quiesced(bridge, context.server, context.epoch, deadline),
         {:ok, _lease} <-
           Session.store(config, :claim_worker, [
             target.id,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         {:ok, remaining} <- remaining(deadline),
         :ok <- bridge.activate(context.server, target.domain_binding, context.epoch, remaining) do
      # Only this explicit action dispatches inside the frozen coordinator's
      # barrier, after the original epoch drains. Busy workers are not bypassed.
      dispatch_stop(target, record, context, bridge, deadline)
    else
      false -> Session.error(:stale_version, :stop)
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :stop)
    end
  end

  defp dispatch_stop(target, record, context, bridge, deadline) do
    stop_and_fence(target, record, context, bridge, deadline)
  rescue
    _ -> uncertain_stop()
  catch
    _, _ -> uncertain_stop()
  end

  defp stop_and_fence(target, record, context, bridge, deadline) do
    with {:ok, remaining} <- remaining(deadline) do
      reference = Target.connection(target, record)

      reference = %{
        reference
        | budget: %{reference.budget | timeout_ms: min(reference.budget.timeout_ms, remaining)}
      }

      verify_stop(reference, record, context, deadline)
    end
  after
    # Always fence further dispatch, including when stop raises. A passive
    # observation can return busy after setting reconciling. Resolution drains
    # again; normal stop supplies no command Exit or reservation release.
    bridge.quiesce(context.server, context.epoch, max(1, deadline - now()))
  end

  @doc false
  def verify_stop(reference, record, context, deadline \\ nil) do
    deadline = deadline || now() + reference.budget.timeout_ms

    with {:ok, remaining} <- remaining(deadline) do
      reference = %{
        reference
        | budget: %{reference.budget | timeout_ms: min(reference.budget.timeout_ms, remaining)}
      }

      case Backend.stop(reference, record.machine_name) do
        {:ok, %{state: :stopped} = stopped} ->
          verify_stopped(reference, record, stopped, context, deadline)

        {:error, %Error{}} = error ->
          error

        _ ->
          uncertain_stop()
      end
    end
  end

  defp verify_stopped(reference, record, stopped, context, deadline) do
    with true <- DiskExpansion.matches?(record, stopped),
         {:ok, remaining} <- remaining(deadline),
         {:ok, health} <-
           Call.health(context, %{reference.budget | timeout_ms: min(1000, remaining)}),
         true <- health.epoch == context.epoch,
         do: {:ok, stopped},
         else: (_ -> uncertain_stop())
  end

  @doc false
  def await_quiesced(bridge, server, epoch, deadline) do
    # Retain the authority barrier and pinned epoch while old Port records drain.
    # Only this pre-dispatch quiescence may repeat; SDK stop never runs here.
    with {:ok, remaining} <- remaining(deadline) do
      case bridge.quiesce(server, epoch, remaining) do
        {:error, %Error{category: :admission_exhausted, evidence: :not_dispatched}} ->
          Process.sleep(min(25, max(0, deadline - now())))
          await_quiesced(bridge, server, epoch, deadline)

        result ->
          result
      end
    end
  end

  defp remaining(deadline) do
    case deadline - now() do
      timeout when timeout > 0 -> {:ok, timeout}
      _ -> {:error, %Error{category: :expired, operation: :stop, evidence: :not_dispatched}}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp uncertain_stop,
    do: {:error, %Error{category: :unknown, operation: :stop, evidence: :dispatch_uncertain}}
end
