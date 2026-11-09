defmodule SmolBox.Runtime.NativeBranchBacking do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.{BranchBackingRelease, BranchCompletion}

  alias SmolBox.Runtime.{
    BranchObservation,
    Deadline,
    MachineSession,
    NativeResolution,
    Session,
    Target
  }

  # A saved acknowledgement is historical and idempotent. Returning the closed
  # record requires neither a replacement helper nor another namespace query.
  def run(
        _config,
        _coordinator,
        %{
          branch: %{
            state: :closed,
            native_authority: %{backing: %{proof: %BranchBackingRelease{}}}
          }
        } = child
      ) do
    if ManagedMachine.validate(child) == :ok,
      do: {:ok, child},
      else: Session.error(:identity_conflict, :branch)
  end

  def run(config, coordinator, child) do
    with {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- Target.require_operation(worker, :release_branch_backing) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        disposition(child),
        fn pinned ->
          release(config, parent, child, pinned, deadline)
        end,
        deadline
      )
    end
  end

  # Partial and unbooted disposal share this backing coordinator, but their
  # uncertain original history must still pass through conservative recovery.
  defp disposition(%{
         branch: %{native_authority: %{completion: %BranchCompletion{}}}
       }),
       do: {:ordinary_branch, :branch_release_storage}

  defp disposition(_), do: :branch_release_storage

  defp release(config, parent, child, worker, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, child} <-
           MachineSession.store(config, :branch_backing_accept, [
             ManagedMachine.key(parent),
             Session.guard(parent),
             child.id,
             child.version,
             true,
             config.clock.now()
           ]),
         {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, [proof]} <- observe(config, parent, child, worker, deadline),
         do: uncertain(commit(config, child, proof, deadline))
  end

  defp commit(config, child, proof, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         {:ok, _} <- remaining(deadline),
         do:
           MachineSession.store(config, :branch_release_storage, [
             child.branch.source,
             Session.guard(current),
             child.id,
             proof,
             config.clock.now()
           ])
  end

  defp observe(config, parent, child, worker, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      reference =
        Backend.bounded(Target.connection(worker),
          timeout_ms: timeout,
          max_request_bytes: 84 * 1024,
          max_response_bytes: 72 * 1024
        )

      worker = %{worker | connection: reference}
      io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout}

      MachineSession.io(config, io_record, fn ->
        BranchObservation.storage_release(worker, parent, child)
      end)
    end
  end

  defp remaining(deadline), do: Deadline.remaining(deadline, :branch)

  defp uncertain(result), do: Error.uncertain(result, :branch)
  defp now, do: System.monotonic_time(:millisecond)
end
