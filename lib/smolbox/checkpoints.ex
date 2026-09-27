defmodule SmolBox.Checkpoints do
  @moduledoc """
  Managed capture of idle offline memory and disks, and explicit independent restore.

  Source machines opt in with `checkpointable: true` and start on an approved
  1.19.0 worker. Captures have durable identities independent of executions.
  A captured result still holds the operation slot until the host confirms that
  pending requests and worker staging are quiescent. There is no automatic replay,
  checkpoint expiry, artifact deletion, live branching or in-place rollback.
  """
  alias SmolBox.{
    Checkpoint,
    CheckpointCapture,
    CheckpointCaptureSpec,
    CheckpointIO,
    Client,
    Error,
    Machine,
    Machines,
    ManagedMachine,
    ManagedMachineSpec,
    Runtime
  }

  alias SmolBox.Runtime.Checkpoints, as: CaptureRuntime
  alias SmolBox.Runtime.{MachineSession, Session}

  @spec capture(SmolBox.runtime(), ManagedMachine.key(), CheckpointCaptureSpec.t()) ::
          {:ok, CheckpointCapture.handle()} | {:error, Error.t()}
  def capture(runtime, machine, spec) do
    with :ok <- CheckpointCaptureSpec.validate(spec),
         {:ok, config} <- configuration(runtime),
         {:ok, record} <- Machines.inspect(runtime, machine) do
      fingerprint = CheckpointCaptureSpec.fingerprint(spec, machine, config.fingerprint_key)

      case record.captures[spec.id] do
        %CheckpointCapture{fingerprint: ^fingerprint} -> {:ok, handle(record, spec.id)}
        %CheckpointCapture{} -> Session.error(:identity_conflict, :checkpoint)
        nil -> accept(config, record, spec, fingerprint)
      end
    end
  end

  defp accept(config, m, spec, fingerprint) do
    with {:ok, worker} <- MachineSession.worker(config, m),
         true <- CaptureRuntime.approved?(worker, spec),
         {:ok, saved} <-
           MachineSession.store(config, :capture_accept, [
             ManagedMachine.key(m),
             spec,
             fingerprint,
             worker.capacity,
             config.clock.now()
           ]),
         do: {:ok, handle(saved, spec.id)},
         else: (
           false -> Session.error(:unsupported_capability, :checkpoint)
           error -> error
         )
  end

  @doc "Read durable evidence without contacting the worker."
  @spec fetch(SmolBox.runtime(), CheckpointCapture.handle()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def fetch(runtime, {scope, machine, id}) do
    with {:ok, record} <- Machines.inspect(runtime, {scope, machine}) do
      case record.captures[id] do
        %CheckpointCapture{} = capture -> {:ok, capture}
        _ -> Session.error(:not_found, :checkpoint)
      end
    end
  end

  def fetch(_, _), do: Session.error(:validation, :checkpoint)

  @doc "Wait for captured, unknown or terminal evidence. Timeout only stops waiting."
  @spec await(SmolBox.runtime(), CheckpointCapture.handle(), non_neg_integer()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def await(runtime, handle, timeout_ms) do
    if SmolBox.Validation.integer?(timeout_ms, 0, 900_000),
      do: wait(runtime, handle, System.monotonic_time(:millisecond) + timeout_ms),
      else: Session.error(:validation, :checkpoint)
  end

  defp wait(runtime, handle, deadline) do
    with {:ok, r} <- fetch(runtime, handle) do
      cond do
        CheckpointCapture.terminal?(r) or r.state in [:captured, :unknown] ->
          {:ok, r}

        System.monotonic_time(:millisecond) >= deadline ->
          Session.error(:expired, :checkpoint)

        true ->
          receive do
          after
            25 -> wait(runtime, handle, deadline)
          end
      end
    end
  end

  @doc "Cancel before dispatch; otherwise retain unknown work and reservations. Never removes files."
  @spec cancel(SmolBox.runtime(), CheckpointCapture.handle()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def cancel(runtime, {scope, machine, id} = handle) do
    with {:ok, _} <- fetch(runtime, handle),
         {:ok, config} <- configuration(runtime),
         {:ok, saved} <-
           MachineSession.store(config, :capture_cancel, [
             {scope, machine},
             id,
             config.clock.now()
           ]),
         do: {:ok, saved.captures[id]}
  end

  def cancel(_, _), do: Session.error(:validation, :checkpoint)

  @doc """
  After fencing prior requests and confirming capture/staging quiescence, pass
  `quiesced: true` and the current source version. Running/stopped observation or
  an expired lease alone cannot establish quiescence. Unknown results stay unknown;
  no output file is adopted. Source ownership is verified before unlocking it.
  """
  @spec resolve(SmolBox.runtime(), CheckpointCapture.handle(), pos_integer(), keyword()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def resolve(runtime, {scope, machine, id} = handle, version, options) do
    with true <-
           SmolBox.Validation.keys?(options, [:quiesced, :disposition]) and
             options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :present),
         true <- disposition in [:present, :deleted],
         {:ok, _} <- fetch(runtime, handle),
         {:ok, config} <- configuration(runtime),
         {:ok, m} <-
           MachineSession.store(config, :claim_version, [
             {scope, machine},
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         {:ok, worker} <- MachineSession.worker(config, m),
         {:ok, observed} <-
           MachineSession.io(config, %{m | operation_deadline_ms: nil}, fn ->
             observe(worker.client, m.machine_name, disposition)
           end),
         true <- observed == :absent or Machine.same_incarnation?(m.created_machine, observed),
         {:ok, current} <- MachineSession.claim(config, {scope, machine}),
         {:ok, saved} <-
           MachineSession.store(config, :capture_resolve, [
             {scope, machine},
             Session.guard(current),
             id,
             observed,
             config.clock.now()
           ]),
         do: {:ok, saved.captures[id]},
         else: (
           false -> Session.error(:validation, :checkpoint)
           error -> error
         )
  end

  def resolve(_, _, _, _), do: Session.error(:validation, :checkpoint)

  @doc """
  Release retained capture accounting after the host removes all retained copies
  and partial output. Requires `artifacts_removed: true`; local complete and partial
  paths must be absent. Never deletes artifacts or invalidates independent restores.
  History and request identity remain. Only completed/resolved captures qualify.
  """
  @spec release(SmolBox.runtime(), CheckpointCapture.handle(), keyword()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def release(runtime, {scope, machine, id} = handle, options) do
    with true <- options == [artifacts_removed: true],
         {:ok, r} <- fetch(runtime, handle),
         true <- CheckpointIO.absent?(r),
         {:ok, config} <- configuration(runtime),
         {:ok, current} <- MachineSession.claim(config, {scope, machine}),
         {:ok, saved} <-
           MachineSession.store(config, :capture_release, [
             {scope, machine},
             Session.guard(current),
             id,
             config.clock.now()
           ]),
         do: {:ok, saved.captures[id]},
         else: (
           false -> Session.error(:validation, :checkpoint)
           error -> error
         )
  end

  def release(_, _, _), do: Session.error(:validation, :checkpoint)

  @doc "Restore a completed capture as a new machine using an explicitly registered worker checkpoint approval."
  @spec restore(SmolBox.runtime(), CheckpointCapture.handle(), Checkpoint.t(), keyword()) ::
          {:ok, ManagedMachine.key()} | {:error, Error.t()}
  def restore(runtime, handle, approval, options) do
    with :ok <- Checkpoint.validate(approval),
         true <- SmolBox.Validation.keys?(options, [:scope, :id]),
         {:ok, %{state: :completed, released_at_ms: nil, result: result}} <-
           fetch(runtime, handle),
         true <-
           approval.sha256 == result.sha256 and approval.profile == result.profile and
             approval.platform == result.platform and approval.architecture == result.architecture and
             approval.runtime_version == result.runtime_version,
         {:ok, spec} <-
           ManagedMachineSpec.new(
             scope: options[:scope],
             id: options[:id],
             artifact: Checkpoint.artifact(approval),
             profile: approval.profile,
             checkpointable: true
           ),
         true <- {spec.scope, spec.id} != elem_machine(handle),
         do: Machines.create(runtime, spec),
         else: (
           {:error, _} = error -> error
           _ -> Session.error(:identity_conflict, :checkpoint)
         )
  end

  defp observe(client, name, :present), do: Client.inspect_machine(client, name)

  defp observe(client, name, :deleted) do
    case Client.inspect_machine(client, name) do
      {:error, %{category: :not_found}} -> {:ok, :absent}
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :checkpoint)
    end
  end

  defp elem_machine({scope, machine, _}), do: {scope, machine}
  defp handle(m, id), do: {m.scope, m.id, id}

  defp configuration(runtime) do
    with {:ok, config} <- GenServer.call(Runtime.coordinator(runtime), :config),
         true <- config.managed_machines,
         {:ok, %{managed_checkpoints: 1}} <- Session.store(config, :capabilities, []),
         do: {:ok, config},
         else: (
           {:error, _} = error -> error
           _ -> Session.error(:unsupported_capability, :checkpoint)
         )
  rescue
    _ -> Session.error(:unknown, :runtime)
  catch
    :exit, _ -> Session.error(:unknown, :runtime)
  end
end
