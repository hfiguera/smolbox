defmodule SmolBox.Runtime.Checkpoints do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{
    Backend,
    CheckpointArtifact,
    CheckpointCapture,
    CheckpointIO,
    CheckpointResult,
    Error,
    Machine,
    ManagedMachine
  }

  alias SmolBox.Runtime.{MachineSession, Session, WorkerHealth}

  def run(config, machine) do
    capture = machine.captures[machine.active_capture]

    case capture.state do
      :accepted ->
        prepare(config, machine, capture)

      :dispatching ->
        unknown(config, machine, capture, %Error{category: :unknown, operation: :checkpoint})

      _ ->
        MachineSession.write(config, machine, next_due_at_ms: config.clock.now() + 60_000)
    end
  end

  def approved?(worker, spec),
    do:
      Target.supports_feature?(worker, :checkpoints) and
        spec.policy in worker.checkpoint_policies

  def advance(config, machine, capture, changes) do
    with {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(machine)),
         do:
           MachineSession.store(config, :capture_advance, [
             ManagedMachine.key(machine),
             Session.guard(current),
             capture.spec.id,
             capture.state,
             changes,
             config.clock.now()
           ])
  end

  defp prepare(config, m, c) do
    result = MachineSession.io(config, m, fn -> preflight(config, m, c) end)

    case result do
      :ok ->
        dispatch(config, m, c)

      {:error, error} ->
        advance(config, m, c, state: :failed, error: error)

      _ ->
        advance(config, m, c,
          state: :failed,
          error: %Error{category: :protocol, operation: :checkpoint}
        )
    end
  end

  defp preflight(config, m, c) do
    with {:ok, worker} <- MachineSession.worker(config, m),
         true <- approved?(worker, c.spec),
         :ok <- WorkerHealth.check(worker, config.clock),
         {:ok, observed} <-
           Backend.checkpoint_preflight(Target.connection(worker, m), m.machine_name),
         true <- source_matches?(m, observed),
         :ok <- CheckpointIO.vacant?(c) do
      :ok
    else
      {:error, error} -> {:error, %{error | evidence: :not_dispatched}}
      _ -> Session.error(:identity_conflict, :checkpoint)
    end
  end

  defp dispatch(config, m, c) do
    with {:ok, intent} <- advance(config, m, c, state: :dispatching),
         {:ok, worker} <- MachineSession.worker(config, intent) do
      pending = intent.captures[c.spec.id]

      result =
        MachineSession.io(config, intent, fn ->
          {:operation_result, capture(worker, intent, pending)}
        end)

      receive_result(config, intent, pending, worker, result)
    end
  end

  defp capture(worker, machine, capture) do
    path = CheckpointCapture.path(capture)

    with {:ok, receipt} <-
           Backend.capture_checkpoint(
             Target.connection(worker, machine),
             machine.machine_name,
             path,
             capture.spec.policy.max_bytes
           ),
         :ok <- CheckpointArtifact.verify(path, receipt, machine.spec.profile, worker) do
      {:ok, receipt}
    end
  end

  defp receive_result(config, m, c, worker, {:operation_result, {:ok, receipt}}) do
    result = %CheckpointResult{
      path: CheckpointCapture.path(c),
      sha256: receipt.sha256,
      size_bytes: receipt.size_bytes,
      profile: m.spec.profile,
      platform: worker.platform,
      architecture: worker.architecture,
      runtime_version: Target.sdk_version(worker)
    }

    with :ok <- CheckpointResult.validate(result),
         do: advance(config, m, c, captured_changes(m, receipt, result))
  end

  defp receive_result(
         config,
         m,
         c,
         _worker,
         {:operation_result, {:error, %{evidence: :not_dispatched} = error}}
       ),
       do: advance(config, m, c, state: :failed, error: error)

  defp receive_result(config, m, c, _worker, _),
    do: unknown(config, m, c, %Error{category: :unknown, operation: :checkpoint})

  defp unknown(config, m, c, error),
    do: advance(config, m, c, state: :unknown, error: %{error | evidence: :unknown})

  defp captured_changes(%{backend_assignment: %{version: 2}}, receipt, result),
    do: [
      state: :captured,
      result: result,
      native_transition: Map.get(receipt, :native_transition)
    ]

  defp captured_changes(_m, _receipt, result), do: [state: :captured, result: result]

  def source_matches?(%{backend_assignment: %{version: 2}} = m, observed),
    do: SmolBox.DiskExpansion.matches?(m, observed)

  def source_matches?(m, observed), do: Machine.same_incarnation?(m.created_machine, observed)
end
