defmodule SmolBox.Runtime.NativeUnbootedBranchRetirement do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.{NativeBranchRetirement, UnbootedBranchChildAbsence}
  alias SmolBox.Runtime.{Deadline, MachineSession, NativeResolution, Session, Target}

  def run(
        _,
        _,
        %{
          branch: %{
            state: state,
            native_authority: %{retirement: %{proof: %UnbootedBranchChildAbsence{}}}
          }
        } = child
      )
      when state in [:retired, :backing_pending, :closed] do
    if ManagedMachine.validate(child) == :ok,
      do: {:ok, child},
      else: Session.error(:identity_conflict, :branch)
  end

  def run(config, coordinator, child) do
    with :ok <- ManagedMachine.validate(child),
         true <- NativeBranchRetirement.eligible?(child),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- Target.require_operation(worker, :retire_unbooted_branch) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        :branch_retire,
        fn pinned ->
          resolve(config, parent, child, pinned, deadline)
        end,
        deadline
      )
    else
      false -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp resolve(config, parent, child, worker, deadline) do
    with {:ok, timeout} <- Deadline.remaining(deadline, :branch),
         {:ok, proof} <- observe(config, parent, child, worker, timeout),
         do: uncertain(commit(config, child, proof, deadline))
  end

  defp observe(config, parent, child, worker, timeout) do
    reference =
      worker
      |> Target.connection(parent)
      |> Backend.bounded(
        timeout_ms: timeout,
        max_request_bytes: 72 * 1024,
        max_response_bytes: 72 * 1024
      )

    io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout}

    case MachineSession.io(config, io_record, fn ->
           {:native_response, Backend.retire_unbooted_branch(reference, parent, child)}
         end) do
      {:native_response, {:ok, %UnbootedBranchChildAbsence{} = proof}} ->
        if bound?(proof, child, worker),
          do: {:ok, proof},
          else: uncertain(Session.error(:identity_conflict, :branch))

      {:native_response, {:error, %Error{}} = error} ->
        error

      {:error, %Error{}} = error ->
        uncertain(error)

      _ ->
        uncertain(Session.error(:unknown, :branch))
    end
  end

  defp bound?(proof, child, worker) do
    context = Target.connection(worker).context

    case NativeBranchRetirement.request(child) do
      {:ok, request} ->
        UnbootedBranchChildAbsence.matches?(proof, request) and
          UnbootedBranchChildAbsence.epoch(request) == context.epoch and
          UnbootedBranchChildAbsence.platform(request) == Atom.to_string(context.config.platform)

      _ ->
        false
    end
  end

  defp commit(config, child, proof, deadline) do
    with {:ok, _} <- Deadline.remaining(deadline, :branch),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         {:ok, _} <- Deadline.remaining(deadline, :branch),
         do:
           MachineSession.store(config, :branch_retire, [
             child.branch.source,
             Session.guard(current),
             child.id,
             proof,
             config.clock.now()
           ])
  end

  defp uncertain(result), do: Error.uncertain(result, :branch)
  defp now, do: System.monotonic_time(:millisecond)
end
