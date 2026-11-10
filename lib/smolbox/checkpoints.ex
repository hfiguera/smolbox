defmodule SmolBox.Checkpoints do
  alias SmolBox.Runtime.Target

  @moduledoc """
  Managed capture of idle offline memory and disks, and explicit independent restore.

  Source machines opt in with `checkpointable: true` and start on an approved
  1.19.0, 1.20.2 or 1.22.0 worker. Captures have durable identities independent of executions.
  A captured result still holds the operation slot until the host confirms that
  pending requests and worker staging are quiescent. There is no automatic replay,
  checkpoint expiry, artifact deletion, live branching or in-place rollback.
  """
  alias SmolBox.{
    Backend,
    Checkpoint,
    CheckpointCapture,
    CheckpointCaptureSpec,
    CheckpointIO,
    Error,
    Machine,
    Machines,
    ManagedMachine,
    ManagedMachineSpec,
    Runtime
  }

  alias SmolBox.Embedded.{NativeCapture, NativeCaptureResolution}

  alias SmolBox.Runtime.Checkpoints, as: CaptureRuntime
  alias SmolBox.Runtime.{MachineSession, NativeResolution, Session}

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
    with true <- m.spec.profile.network == :offline,
         {:ok, worker} <- MachineSession.worker(config, m),
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
  Embedded resolution freezes target dispatch and serializes against recovery.
  Normal captured completion preserves a previously ready scan only after its
  exact committed result, same helper epoch and worker lease are verified again.
  Exact completed or previously resolved native evidence is observed first;
  without it, exact pre-entry abort requires distinct unchanged-source qualification,
  while an entered capture requires explicit material qualification.
  A live source must remain this engine's originally enrolled PID/birth; a stopped
  source requires verified original-process absence. No capture is replayed,
  guest stopped for resolution or local artifact adopted.
  """
  @spec resolve(SmolBox.runtime(), CheckpointCapture.handle(), pos_integer(), keyword()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def resolve(runtime, {scope, machine, id} = handle, version, options) do
    with true <-
           SmolBox.Validation.keys?(options, [:quiesced, :disposition]) and
             options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :present),
         true <- disposition in [:present, :deleted],
         {:ok, capture} <- fetch(runtime, handle),
         {:ok, config} <- configuration(runtime),
         {:ok, m} <- MachineSession.store(config, :fetch, [{scope, machine}]),
         {:ok, worker} <- MachineSession.worker(config, m) do
      NativeResolution.run(
        config,
        Runtime.coordinator(runtime),
        m,
        worker,
        if(disposition == :present and capture.state == :captured,
          do: {:ordinary_capture, :capture_complete},
          else: disposition
        ),
        fn pinned ->
          resolve_record(config, {scope, machine}, id, version, pinned, disposition)
        end
      )
    else
      false -> Session.error(:validation, :checkpoint)
      error -> error
    end
  end

  def resolve(_, _, _, _), do: Session.error(:validation, :checkpoint)

  @doc """
  Release retained capture accounting after the host removes all retained copies
  and partial output. Requires `artifacts_removed: true`; local complete and partial
  paths must be absent. Never deletes host artifacts or invalidates independent restores.
  History and request identity remain. Only completed/resolved captures qualify.
  Embedded release fences the pinned helper, cleans only its owned private stage,
  and atomically consumes the exact cleanup receipt with released accounting.
  """
  @spec release(SmolBox.runtime(), CheckpointCapture.handle(), keyword()) ::
          {:ok, CheckpointCapture.t()} | {:error, Error.t()}
  def release(runtime, {scope, machine, id} = handle, options) do
    with true <- options == [artifacts_removed: true],
         {:ok, r} <- fetch(runtime, handle),
         true <- CheckpointIO.absent?(r),
         {:ok, config} <- configuration(runtime),
         {:ok, current} <- MachineSession.claim(config, {scope, machine}),
         {:ok, saved} <- release_record(runtime, config, current, id),
         do: {:ok, saved.captures[id]},
         else: (
           false -> Session.error(:validation, :checkpoint)
           error -> error
         )
  end

  def release(_, _, _), do: Session.error(:validation, :checkpoint)

  defp release_record(runtime, config, %{backend_assignment: %{version: 2}} = current, id) do
    capture = current.captures[id]

    if capture.released_at_ms != nil do
      save_release(config, current, id, nil)
    else
      release_pending(runtime, config, current, id, capture.state)
    end
  end

  defp release_record(_runtime, config, current, id), do: save_release(config, current, id, nil)

  defp release_pending(runtime, config, current, id, state)
       when state in [:completed, :resolved_unknown] do
    with {:ok, worker} <- MachineSession.worker(config, current) do
      NativeResolution.run(
        config,
        Runtime.coordinator(runtime),
        current,
        worker,
        :release,
        &release_native(config, current, id, &1)
      )
    end
  end

  defp release_pending(_runtime, _config, _current, _id, _state),
    do: Session.error(:identity_conflict, :checkpoint)

  defp release_native(config, record, id, worker) do
    key = ManagedMachine.key(record)

    with {:ok, current} <- MachineSession.claim(config, key),
         capture = current.captures[id],
         true <- CheckpointIO.absent?(capture),
         {:ok, proof} <-
           MachineSession.io(config, %{current | operation_deadline_ms: nil}, fn ->
             Backend.cleanup_capture(Target.connection(worker, current), capture, true)
           end),
         {:ok, current} <- MachineSession.claim(config, key),
         true <- CheckpointIO.absent?(current.captures[id]),
         do: save_release(config, current, id, proof),
         else: (
           false -> Session.error(:validation, :checkpoint)
           error -> error
         )
  end

  defp save_release(config, current, id, proof) do
    args =
      [ManagedMachine.key(current), Session.guard(current), id] ++
        if(proof == nil, do: [], else: [proof]) ++ [config.clock.now()]

    MachineSession.store(config, :capture_release, args)
  end

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

  defp resolve_record(config, key, id, version, worker, disposition) do
    with {:ok, m} <-
           MachineSession.store(config, :claim_version, [
             key,
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         true <- resolution_intent?(m, id),
         {:ok, observed} <-
           MachineSession.io(config, %{m | operation_deadline_ms: nil}, fn ->
             resolution_observe(worker, m, disposition)
           end),
         true <- observed == :absent or source_valid?(m, observed),
         {:ok, current} <- MachineSession.claim(config, key),
         {:ok, saved} <-
           MachineSession.store(config, :capture_resolve, [
             key,
             Session.guard(current),
             id,
             observed,
             config.clock.now()
           ]) do
      {:ok, saved.captures[id]}
    else
      false -> Session.error(:validation, :checkpoint)
      error -> error
    end
  end

  defp source_valid?(
         %{backend_assignment: %{version: 2}} = m,
         %NativeCaptureResolution{} = resolution
       ),
       do: NativeCapture.resolution_valid?(m, m.captures[m.active_capture], resolution)

  defp source_valid?(%{backend_assignment: %{version: 2}} = m, observed) do
    capture = m.captures[m.active_capture]

    if capture.state == :unknown,
      do: NativeCapture.resolution_valid?(m, capture, observed),
      else: NativeCapture.observation_valid?(m, observed)
  end

  defp source_valid?(m, observed), do: Machine.same_incarnation?(m.created_machine, observed)

  defp resolution_intent?(%{backend_assignment: %{version: 2}} = m, id),
    do: m.active_capture == id and m.captures[id].state in [:captured, :unknown]

  defp resolution_intent?(_m, _id), do: true

  defp observe(client, name, :present), do: Backend.inspect_machine(client, name)

  defp observe(client, name, :deleted) do
    case Backend.inspect_machine(client, name) do
      {:error, %{category: :not_found}} -> {:ok, :absent}
      {:error, _} = error -> error
      _ -> Session.error(:identity_conflict, :checkpoint)
    end
  end

  defp resolution_observe(%{kind: :embedded} = worker, m, :present) do
    client = Target.connection(worker, m)

    if m.captures[m.active_capture].state == :unknown,
      do: Backend.qualify_capture(client, true),
      else: observe(client, m.machine_name, :present)
  end

  defp resolution_observe(worker, m, disposition),
    do: observe(Target.connection(worker, m), m.machine_name, disposition)

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
