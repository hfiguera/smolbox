defmodule SmolBox.Runtime.NativeBranchDeletion do
  @moduledoc false
  alias SmolBox.{Backend, ManagedMachine}
  alias SmolBox.Embedded.{BranchDeletionResolution, ReleasedBranchDeletionResolution}
  alias SmolBox.Runtime.{Deadline, MachineSession, Session, Target}

  # The public resolver already holds the captured helper/controller fence and
  # claimed the expected user version. Keep the same pin through final commit.
  def run(config, child, worker, deadline \\ nil) do
    deadline = deadline || now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

    with :ok <- Target.require_operation(worker, :resolve_branch_deletion),
         {:ok, _} <- Deadline.remaining(deadline, :reconcile),
         {:ok, child} <-
           MachineSession.store(config, :branch_delete_accept, [
             ManagedMachine.key(child),
             Session.guard(child),
             config.clock.now()
           ]),
         {:ok, timeout} <- Deadline.remaining(deadline, :reconcile),
         {:ok, proof}
         when is_struct(proof, BranchDeletionResolution) or
                is_struct(proof, ReleasedBranchDeletionResolution) <-
           observe(config, child, worker, timeout),
         {:ok, _} <- Deadline.remaining(deadline, :reconcile),
         {:ok, fresh} <- MachineSession.claim(config, ManagedMachine.key(child)),
         {:ok, _} <- Deadline.remaining(deadline, :reconcile),
         do:
           MachineSession.store(config, :resolve, [
             ManagedMachine.key(child),
             Session.guard(fresh),
             proof,
             config.clock.now()
           ])
  end

  defp observe(config, child, worker, timeout) do
    reference =
      worker
      |> Target.connection(child)
      |> Backend.bounded(timeout_ms: timeout, max_response_bytes: 8192)

    io_record = %{child | operation_deadline_ms: config.clock.now() + timeout}

    MachineSession.io(config, io_record, fn ->
      Backend.resolve_branch_deletion(reference, child)
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
