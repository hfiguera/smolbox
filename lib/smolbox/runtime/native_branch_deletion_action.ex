defmodule SmolBox.Runtime.NativeBranchDeletionAction do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}

  alias SmolBox.Embedded.{
    NativeBranchDeletionAction,
    NativeBranchDeletionCollection,
    NativeReleasedBranchDeletionCleanup,
    NativeReleasedBranchDeletionContinuation
  }

  alias SmolBox.Runtime.{Deadline, MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child, version, action) do
    with :ok <- ManagedMachine.validate(child),
         true <- child.version == version do
      case saved(child, action) do
        %NativeBranchDeletionCollection{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        %NativeBranchDeletionAction{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        %NativeReleasedBranchDeletionContinuation{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        %NativeReleasedBranchDeletionCleanup{proof: proof} when not is_nil(proof) ->
          {:ok, child}

        _ ->
          dispatch(config, coordinator, child, version, action)
      end
    else
      false -> Session.error(:stale_version, :reconcile)
      _ -> Session.error(:identity_conflict, :reconcile)
    end
  end

  defp saved(%{branch: %{native_authority: %{} = authority}}, action),
    do: Map.get(authority, NativeBranchDeletionAction.field(action))

  defp saved(_, _), do: nil

  def operation(:collect), do: :collect_branch_deletion
  def operation(:continue), do: :continue_branch_deletion
  def operation(:cleanup), do: :cleanup_branch_deletion

  defp dispatch(config, coordinator, child, version, action) do
    with true <- NativeBranchDeletionAction.eligible?(child, action),
         {:ok, worker} <- MachineSession.worker(config, child),
         :ok <- Target.require_operation(worker, operation(action)) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(
        config,
        coordinator,
        child,
        worker,
        {:branch_deletion_action, action},
        fn pinned ->
          claimed(config, child, version, pinned, action, deadline)
        end,
        deadline
      )
    else
      false -> Session.error(:unsupported_capability, :reconcile)
      error -> error
    end
  end

  defp claimed(config, child, version, worker, action, deadline) do
    with {:ok, _} <- Deadline.remaining(deadline, :reconcile),
         {:ok, current} <-
           MachineSession.store(config, :claim_version, [
             ManagedMachine.key(child),
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         {:ok, _} <- Deadline.remaining(deadline, :reconcile),
         do: accepted(config, current, worker, action, deadline)
  end

  defp accepted(config, child, worker, action, deadline) do
    with {:ok, child} <-
           MachineSession.store(config, :branch_delete_action_accept, [
             ManagedMachine.key(child),
             Session.guard(child),
             action,
             config.clock.now()
           ]),
         {:ok, timeout} <- Deadline.remaining(deadline, :reconcile),
         {:ok, proof} <- observe(config, child, worker, action, timeout),
         do: commit(config, child, proof, action, deadline)
  end

  defp observe(config, child, worker, action, timeout) do
    reference =
      worker
      |> Target.connection(child)
      |> Backend.bounded(timeout_ms: timeout, max_response_bytes: 8192)

    io_record = %{child | operation_deadline_ms: config.clock.now() + timeout}

    case MachineSession.io(config, io_record, fn ->
           {:native_response, Backend.invoke(reference, operation(action), [child])}
         end) do
      {:native_response, response} -> response
      {:error, %Error{}} = error -> uncertain(error)
      _ -> uncertain(Session.error(:unknown, :reconcile))
    end
  end

  defp commit(config, child, proof, action, deadline) do
    result =
      with true <- NativeBranchDeletionAction.matches?(saved(child, action), action, proof),
           {:ok, _} <- Deadline.remaining(deadline, :reconcile),
           {:ok, fresh} <- MachineSession.claim(config, ManagedMachine.key(child)),
           {:ok, _} <- Deadline.remaining(deadline, :reconcile) do
        MachineSession.store(config, :branch_delete_action_complete, [
          ManagedMachine.key(child),
          Session.guard(fresh),
          action,
          proof,
          config.clock.now()
        ])
      else
        false -> Session.error(:identity_conflict, :reconcile)
        error -> error
      end

    uncertain(result)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | operation: :reconcile, evidence: :dispatch_uncertain}}

  defp uncertain(result), do: result

  defp now, do: System.monotonic_time(:millisecond)
end
